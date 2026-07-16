[control]
control-node ansible_host=${control_ip} ansible_user=ubuntu

[managed]
%{ for index, ip in node_ips ~}
managed-node-${index + 1} ansible_host=${ip} ansible_user=ubuntu
%{ endfor ~}

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
