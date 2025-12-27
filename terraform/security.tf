# Security Group - Allow all internal traffic + SSH from external
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

  # K3s API server (for external kubeconfig access)
  ingress {
    description = "K3s API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
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

# SSH Key Pair (optional - only created if ssh_public_key is provided)
resource "aws_key_pair" "main" {
  count      = var.ssh_public_key != "" ? 1 : 0
  key_name   = "k3s-perf-test-key"
  public_key = var.ssh_public_key

  tags = {
    Name = "k3s-perf-test-key"
  }
}

# Generate random token for K3s
resource "random_password" "k3s_token" {
  length  = 32
  special = false
}
