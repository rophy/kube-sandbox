# Security Group
resource "aws_security_group" "main" {
  name        = "ubuntu-ec2-sg"
  description = "Security group for Ubuntu EC2"
  vpc_id      = aws_vpc.main.id

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # Allow all outbound
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ubuntu-ec2-sg"
  }
}

# SSH Key Pair (optional - only created if ssh_public_key is provided)
resource "aws_key_pair" "main" {
  count      = var.ssh_public_key != "" ? 1 : 0
  key_name   = "ubuntu-ec2-key"
  public_key = var.ssh_public_key

  tags = {
    Name = "ubuntu-ec2-key"
  }
}
