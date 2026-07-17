terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # REMOTE STATE BACKEND (using your newly created bucket!)
  backend "s3" {
    bucket  = "unique-terraform-state-bucket1"
    key     = "ansible-lab/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}

provider "aws" {
  region = "us-east-1"
}

# 1. Custom Sandbox VPC
resource "aws_vpc" "lab_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "ansible-lab-vpc" }
}

# 2. Private Subnet (No auto public IP)
resource "aws_subnet" "lab_subnet" {
  vpc_id                  = aws_vpc.lab_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = false
  availability_zone       = "us-east-1a"
  tags                    = { Name = "ansible-lab-subnet" }
}

# 3. Internet Gateway & Routes (required only for package updates/egress)
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lab_vpc.id
  tags   = { Name = "ansible-lab-igw" }
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.lab_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "ansible-lab-rt" }
}

resource "aws_route_table_association" "rta" {
  subnet_id      = aws_subnet.lab_subnet.id
  route_table_id = aws_route_table.rt.id
}

# 4. Security Group (Open port 22 internally, closed to public internet)
resource "aws_security_group" "lab_sg" {
  name        = "ansible-lab-sg"
  description = "Secure private SSH group"
  vpc_id      = aws_vpc.lab_vpc.id

  # Allow SSH strictly from within the VPC (e.g. from EICE endpoint)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 5. EC2 Instance Connect Endpoint (EICE) - 100% Free Tunneling Gateway
resource "aws_ec2_instance_connect_endpoint" "eice" {
  subnet_id          = aws_subnet.lab_subnet.id
  security_group_ids = [aws_security_group.lab_sg.id]
  preserve_client_ip = false
  tags               = { Name = "ansible-lab-eice" }
}

# 6. Generate Dynamic SSH Key Pair
resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "aws_key" {
  key_name   = "ansible-lab-key"
  public_key = tls_private_key.ssh_key.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ssh_key.private_key_pem
  filename        = "${path.module}/id_rsa"
  file_permission = "0600"
}

# 7. Fetch Ubuntu AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"] # Canonical
}

# 8. Provision Private Ansible Control Instance (No Public IP)
resource "aws_instance" "control" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.micro"
  key_name                    = aws_key_pair.aws_key.key_name
  vpc_security_group_ids      = [aws_security_group.lab_sg.id]
  subnet_id                   = aws_subnet.lab_subnet.id
  associate_public_ip_address = false
  tags                        = { Name = "ansible-control-node" }
}

# 9. Provision 2 Private Managed Node Instances (No Public IPs)
resource "aws_instance" "managed" {
  count                       = 2
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.micro"
  key_name                    = aws_key_pair.aws_key.key_name
  vpc_security_group_ids      = [aws_security_group.lab_sg.id]
  subnet_id                   = aws_subnet.lab_subnet.id
  associate_public_ip_address = false
  tags                        = { Name = "ansible-managed-node-${count.index + 1}" }
}

# 10. Dynamically Generate Ansible Inventory File (using Instance IDs!)
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/inventory.ini"
  content  = templatefile("${path.module}/templates/inventory.tpl", {
    control_id = aws_instance.control.id,
    node_ids   = aws_instance.managed[*].id
  })
}
