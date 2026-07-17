[control]
control-node ansible_host=${control_id} ansible_user=ubuntu

[managed]
%{ for index, id in node_ids ~}
managed-node-${index + 1} ansible_host=${id} ansible_user=ubuntu
%{ endfor ~}

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ProxyCommand="aws ec2-instance-connect open-tunnel --instance-id %h --port %p --region us-east-1"'
