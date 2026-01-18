# Security Group
resource "aws_security_group" "k3s" {
  name        = "k3s-perf-test-sg"
  description = "Security group for K3s cluster"
  vpc_id      = aws_vpc.main.id

  # Allow all traffic within VPC
  ingress {
    description = "All internal traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # K3s API via nginx TLS termination
  ingress {
    description = "K3s API via nginx"
    from_port   = 16443
    to_port     = 16443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Docker Registry NodePort
  ingress {
    description = "Docker Registry"
    from_port   = 30500
    to_port     = 30500
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
    Name = "k3s-perf-test-sg"
  }
}

# SSH Key Pair
resource "aws_key_pair" "main" {
  key_name   = "k3s-perf-test-key"
  public_key = file("${path.module}/../../.ssh/id_rsa.pub")

  tags = {
    Name = "k3s-perf-test-key"
  }
}

# K3s token
resource "random_password" "k3s_token" {
  length  = 32
  special = false
}
