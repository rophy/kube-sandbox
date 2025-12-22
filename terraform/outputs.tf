output "instance_id" {
  description = "EC2 instance ID"
  value       = module.ubuntu.instance_id
}

output "public_ip" {
  description = "Public IP address"
  value       = module.ubuntu.public_ip
}

output "private_ip" {
  description = "Private IP address"
  value       = module.ubuntu.private_ip
}

output "ssh_command" {
  description = "SSH command to connect"
  value       = var.ssh_public_key != "" ? "ssh -i <private-key> ubuntu@${module.ubuntu.public_ip}" : "Use SSM: aws ssm start-session --target ${module.ubuntu.instance_id} --region ${var.aws_region}"
}

output "availability_zone" {
  description = "Availability zone used"
  value       = local.az
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}
