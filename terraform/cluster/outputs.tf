output "db_node_public_ip" {
  description = "Public IP of DB node (K3s server) - Elastic IP"
  value       = aws_eip.db.public_ip
}

output "db_node_private_ip" {
  description = "Private IP of DB node"
  value       = aws_instance.db.private_ip
}

output "stream_node_public_ip" {
  description = "Public IP of Stream node - Elastic IP"
  value       = aws_eip.stream.public_ip
}

output "stream_node_private_ip" {
  description = "Private IP of Stream node"
  value       = aws_instance.stream.private_ip
}

output "client_node_public_ip" {
  description = "Public IP of Client node - Elastic IP"
  value       = aws_eip.client.public_ip
}

output "client_node_private_ip" {
  description = "Private IP of Client node"
  value       = aws_instance.client.private_ip
}

output "k3s_token" {
  description = "K3s cluster token"
  value       = random_password.k3s_token.result
  sensitive   = true
}

output "ssh_commands" {
  description = "SSH commands to connect to each node"
  value = {
    db     = "ssh -i .ssh/id_rsa ec2-user@${aws_eip.db.public_ip}"
    stream = "ssh -i .ssh/id_rsa ec2-user@${aws_eip.stream.public_ip}"
    client = "ssh -i .ssh/id_rsa ec2-user@${aws_eip.client.public_ip}"
  }
}

output "kubeconfig_command" {
  description = "Command to get kubeconfig from server"
  value       = "ssh -i .ssh/id_rsa ec2-user@${aws_eip.db.public_ip} 'cat /tmp/kubeconfig-external.yaml' > kubeconfig.yaml"
}

output "availability_zone" {
  description = "Availability zone used"
  value       = local.az
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}
