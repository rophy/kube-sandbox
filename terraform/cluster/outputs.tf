output "master_public_ip" {
  description = "Public IP of master node (K3s server) - Elastic IP"
  value       = aws_eip.master.public_ip
}

output "master_private_ip" {
  description = "Private IP of master node"
  value       = aws_instance.master.private_ip
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes"
  value       = { for name, instance in aws_instance.worker : name => instance.private_ip }
}

output "worker_public_ips" {
  description = "Ephemeral public IPv4 of worker nodes (may change on stop/start)"
  value       = { for name, instance in aws_instance.worker : name => instance.public_ip }
}

output "k3s_token" {
  description = "K3s cluster token"
  value       = random_password.k3s_token.result
  sensitive   = true
}

output "ssh_commands" {
  description = "Access commands: SSH to master via EIP; workers via SSM Session Manager (no EIP)"
  value = merge(
    { master = "ssh -i .ssh/id_rsa ec2-user@${aws_eip.master.public_ip}" },
    { for name, instance in aws_instance.worker : name => "aws ssm start-session --target ${instance.id}" }
  )
}

output "kubeconfig_command" {
  description = "Command to get kubeconfig from server"
  value       = "ssh -i .ssh/id_rsa ec2-user@${aws_eip.master.public_ip} 'cat /tmp/kubeconfig-external.yaml' > kubeconfig.yaml"
}

output "availability_zone" {
  description = "Primary AZ (master's AZ; default for workers without an explicit `az`)"
  value       = local.az
}

output "availability_zones" {
  description = "All AZs with subnets in this VPC"
  value       = local.azs
}

output "subnet_ids" {
  description = "Subnet IDs keyed by AZ"
  value       = { for az, sn in aws_subnet.public : az => sn.id }
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}
