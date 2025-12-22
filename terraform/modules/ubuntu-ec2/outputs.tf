output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.ubuntu.id
}

output "public_ip" {
  description = "Public IP address"
  value       = aws_instance.ubuntu.public_ip
}

output "private_ip" {
  description = "Private IP address"
  value       = aws_instance.ubuntu.private_ip
}

output "ami_id" {
  description = "AMI ID used"
  value       = data.aws_ami.ubuntu.id
}
