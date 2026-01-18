output "master_public_ip" {
  description = "Public IP of master node (K3s server) - Elastic IP"
  value       = aws_eip.master.public_ip
}

output "master_private_ip" {
  description = "Private IP of master node"
  value       = aws_instance.master.private_ip
}

output "worker1_public_ip" {
  description = "Public IP of worker1 node - Elastic IP"
  value       = aws_eip.worker1.public_ip
}

output "worker1_private_ip" {
  description = "Private IP of worker1 node"
  value       = aws_instance.worker1.private_ip
}

output "worker2_public_ip" {
  description = "Public IP of worker2 node - Elastic IP"
  value       = aws_eip.worker2.public_ip
}

output "worker2_private_ip" {
  description = "Private IP of worker2 node"
  value       = aws_instance.worker2.private_ip
}

output "k3s_token" {
  description = "K3s cluster token"
  value       = random_password.k3s_token.result
  sensitive   = true
}

output "ssh_commands" {
  description = "SSH commands to connect to each node"
  value = {
    master  = "ssh -i .ssh/id_rsa ec2-user@${aws_eip.master.public_ip}"
    worker1 = "ssh -i .ssh/id_rsa ec2-user@${aws_eip.worker1.public_ip}"
    worker2 = "ssh -i .ssh/id_rsa ec2-user@${aws_eip.worker2.public_ip}"
  }
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
