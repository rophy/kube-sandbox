# Get latest Amazon Linux 2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# IAM Role for EC2 (needed for SSM and basic operations)
resource "aws_iam_role" "ec2" {
  name = "k3s-perf-test-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "k3s-perf-test-ec2-profile"
  role = aws_iam_role.ec2.name
}

# User data for K3s server (DB node)
locals {
  k3s_server_userdata = <<-EOF
    #!/bin/bash
    set -e

    # Install dependencies (curl-minimal already present on AL2023)
    dnf install -y jq

    # Disable firewalld (K3s manages iptables)
    systemctl disable --now firewalld || true

    # Install K3s server with disabled components
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s - \
      --token "${random_password.k3s_token.result}" \
      --disable traefik \
      --disable servicelb \
      --disable local-storage \
      --node-label "workload=db" \
      --tls-san "$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)" \
      --write-kubeconfig-mode 644

    # Wait for K3s to be ready
    until kubectl get nodes; do sleep 5; done

    # Store kubeconfig with public IP for external access
    PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
    sed "s/127.0.0.1/$PUBLIC_IP/g" /etc/rancher/k3s/k3s.yaml > /tmp/kubeconfig-external.yaml
    chmod 644 /tmp/kubeconfig-external.yaml

    echo "K3s server ready"
  EOF

  k3s_agent_stream_userdata = <<-EOF
    #!/bin/bash
    set -e

    # Install dependencies (curl-minimal already present on AL2023)
    dnf install -y jq

    # Disable firewalld
    systemctl disable --now firewalld || true

    # Wait for server to be ready (retry logic)
    SERVER_IP="${aws_instance.db.private_ip}"
    until curl -sk "https://$SERVER_IP:6443" >/dev/null 2>&1; do
      echo "Waiting for K3s server..."
      sleep 10
    done

    # Install K3s agent
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent" sh -s - \
      --server "https://$SERVER_IP:6443" \
      --token "${random_password.k3s_token.result}" \
      --node-label "workload=stream" \
      --node-taint "workload=stream:NoSchedule"

    echo "K3s agent (stream) ready"
  EOF

  k3s_agent_client_userdata = <<-EOF
    #!/bin/bash
    set -e

    # Install dependencies (curl-minimal already present on AL2023)
    dnf install -y jq

    # Disable firewalld
    systemctl disable --now firewalld || true

    # Wait for server to be ready (retry logic)
    SERVER_IP="${aws_instance.db.private_ip}"
    until curl -sk "https://$SERVER_IP:6443" >/dev/null 2>&1; do
      echo "Waiting for K3s server..."
      sleep 10
    done

    # Install K3s agent
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent" sh -s - \
      --server "https://$SERVER_IP:6443" \
      --token "${random_password.k3s_token.result}" \
      --node-label "workload=client" \
      --node-taint "workload=client:NoSchedule"

    echo "K3s agent (client) ready"
  EOF
}

# DB Node - K3s Server (On-Demand or Spot)
resource "aws_instance" "db" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.db_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.k3s.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = var.ssh_public_key != "" ? aws_key_pair.main[0].key_name : null

  user_data = local.k3s_server_userdata

  instance_market_options {
    market_type = var.use_spot_instances ? "spot" : null

    dynamic "spot_options" {
      for_each = var.use_spot_instances ? [1] : []
      content {
        instance_interruption_behavior = "terminate"
        spot_instance_type             = "one-time"
      }
    }
  }

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  tags = {
    Name     = "k3s-db"
    Workload = "db"
    Role     = "server"
  }
}

# Stream Node - K3s Agent
resource "aws_instance" "stream" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.stream_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.k3s.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = var.ssh_public_key != "" ? aws_key_pair.main[0].key_name : null

  user_data = local.k3s_agent_stream_userdata

  instance_market_options {
    market_type = var.use_spot_instances ? "spot" : null

    dynamic "spot_options" {
      for_each = var.use_spot_instances ? [1] : []
      content {
        instance_interruption_behavior = "terminate"
        spot_instance_type             = "one-time"
      }
    }
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  depends_on = [aws_instance.db]

  tags = {
    Name     = "k3s-stream"
    Workload = "stream"
    Role     = "agent"
  }
}

# Client Node - K3s Agent
resource "aws_instance" "client" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.client_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.k3s.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = var.ssh_public_key != "" ? aws_key_pair.main[0].key_name : null

  user_data = local.k3s_agent_client_userdata

  instance_market_options {
    market_type = var.use_spot_instances ? "spot" : null

    dynamic "spot_options" {
      for_each = var.use_spot_instances ? [1] : []
      content {
        instance_interruption_behavior = "terminate"
        spot_instance_type             = "one-time"
      }
    }
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  depends_on = [aws_instance.db]

  tags = {
    Name     = "k3s-client"
    Workload = "client"
    Role     = "agent"
  }
}
