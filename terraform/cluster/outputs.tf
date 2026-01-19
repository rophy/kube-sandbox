output "master_public_ip" {
  description = "Public IP of master node (K3s server) - Elastic IP"
  value       = aws_eip.master.public_ip
}

output "master_private_ip" {
  description = "Private IP of master node"
  value       = aws_instance.master.private_ip
}

output "worker_public_ips" {
  description = "Public IPs of worker nodes - Elastic IPs"
  value       = { for name, eip in aws_eip.worker : name => eip.public_ip }
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes"
  value       = { for name, instance in aws_instance.worker : name => instance.private_ip }
}

output "k3s_token" {
  description = "K3s cluster token"
  value       = random_password.k3s_token.result
  sensitive   = true
}

output "ssh_commands" {
  description = "SSH commands to connect to each node"
  value = merge(
    { master = "ssh -i .ssh/id_rsa ec2-user@${aws_eip.master.public_ip}" },
    { for name, eip in aws_eip.worker : name => "ssh -i .ssh/id_rsa ec2-user@${eip.public_ip}" }
  )
}

output "kubeconfig_command" {
  description = "Command to get kubeconfig from server"
  value       = "ssh -i .ssh/id_rsa ec2-user@${aws_eip.master.public_ip} 'cat /tmp/kubeconfig-external.yaml' > kubeconfig.yaml"
}

output "availability_zone" {
  description = "Availability zone used"
  value       = local.az
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}
