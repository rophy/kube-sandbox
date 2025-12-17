output "db_node_public_ip" {
  description = "Public IP of DB node (K3s server)"
  value       = aws_instance.db.public_ip
}

output "db_node_private_ip" {
  description = "Private IP of DB node"
  value       = aws_instance.db.private_ip
}

output "stream_node_public_ip" {
  description = "Public IP of Stream node"
  value       = aws_instance.stream.public_ip
}

output "stream_node_private_ip" {
  description = "Private IP of Stream node"
  value       = aws_instance.stream.private_ip
}

output "client_node_public_ip" {
  description = "Public IP of Client node"
  value       = aws_instance.client.public_ip
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

output "ssh_command_db" {
  description = "SSH command to connect to DB node"
  value       = var.ssh_public_key != "" ? "ssh -i <private-key> ec2-user@${aws_instance.db.public_ip}" : "Use SSM: aws ssm start-session --target ${aws_instance.db.id}"
}

output "kubeconfig_command" {
  description = "Command to get kubeconfig from server"
  value       = "ssh ec2-user@${aws_instance.db.public_ip} 'cat /tmp/kubeconfig-external.yaml' > kubeconfig.yaml"
}

output "ssm_session_commands" {
  description = "SSM session commands for each node"
  value = {
    db     = "aws ssm start-session --target ${aws_instance.db.id}"
    stream = "aws ssm start-session --target ${aws_instance.stream.id}"
    client = "aws ssm start-session --target ${aws_instance.client.id}"
  }
}

output "availability_zone" {
  description = "Availability zone used"
  value       = local.az
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}
