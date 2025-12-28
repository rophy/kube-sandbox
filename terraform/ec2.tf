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

# EBS CSI Driver policy for dynamic volume provisioning
resource "aws_iam_role_policy" "ebs_csi" {
  name = "k3s-ebs-csi-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateSnapshot",
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:ModifyVolume",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInstances",
          "ec2:DescribeSnapshots",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumesModifications",
          "ec2:CreateVolume",
          "ec2:DeleteVolume",
          "ec2:DeleteSnapshot",
          "ec2:CreateTags"
        ]
        Resource = "*"
      }
    ]
  })
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

# Wait for public IP to be assigned (important for TLS SAN)
echo "Waiting for public IP..."
PUBLIC_IP=""
for i in {1..60}; do
  # Use IMDSv2 with token
  TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)
  if [ -n "$TOKEN" ]; then
    PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 || true)
  fi
  if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "404" ] && [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Got public IP: $PUBLIC_IP"
    break
  fi
  echo "Waiting for public IP... attempt $i"
  sleep 2
done

if [ -z "$PUBLIC_IP" ] || ! [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: Failed to get public IP after 60 attempts"
  exit 1
fi

# Create K3s manifests directory for auto-deploy
mkdir -p /var/lib/rancher/k3s/server/manifests

# Configure containerd to use insecure local registry
# Use localhost:30500 as endpoint since nodes can't resolve k8s DNS names
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/registries.yaml << 'REGISTRIES'
mirrors:
  "registry.registry.svc.cluster.local:30500":
    endpoint:
      - "http://localhost:30500"
  "localhost:30500":
    endpoint:
      - "http://localhost:30500"
REGISTRIES

# Write EBS CSI Driver manifest
cat > /var/lib/rancher/k3s/server/manifests/ebs-csi-driver.yaml << 'EBSCSI'
${file("${path.module}/../manifests/ebs-csi-driver.yaml")}
EBSCSI

# Write EBS StorageClass manifest
cat > /var/lib/rancher/k3s/server/manifests/ebs-storageclass.yaml << 'EBSSC'
${file("${path.module}/../manifests/ebs-storageclass.yaml")}
EBSSC

# Install K3s server with disabled components
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s - \
  --token "${random_password.k3s_token.result}" \
  --disable traefik \
  --disable servicelb \
  --disable local-storage \
  --node-label "workload=db" \
  --tls-san "$PUBLIC_IP" \
  --write-kubeconfig-mode 644

# Wait for K3s to be ready
until kubectl get nodes; do sleep 5; done

# Store kubeconfig with public IP for external access (PUBLIC_IP already set above)
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

# Configure containerd to use insecure local registry
# Use localhost:30500 as endpoint since nodes can't resolve k8s DNS names
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/registries.yaml << 'REGISTRIES'
mirrors:
  "registry.registry.svc.cluster.local:30500":
    endpoint:
      - "http://localhost:30500"
  "localhost:30500":
    endpoint:
      - "http://localhost:30500"
REGISTRIES

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

# Configure containerd to use insecure local registry
# Use localhost:30500 as endpoint since nodes can't resolve k8s DNS names
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/registries.yaml << 'REGISTRIES'
mirrors:
  "registry.registry.svc.cluster.local:30500":
    endpoint:
      - "http://localhost:30500"
  "localhost:30500":
    endpoint:
      - "http://localhost:30500"
REGISTRIES

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

  dynamic "instance_market_options" {
    for_each = var.use_spot_instances ? [1] : []
    content {
      market_type = "spot"
      spot_options {
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

  dynamic "instance_market_options" {
    for_each = var.use_spot_instances ? [1] : []
    content {
      market_type = "spot"
      spot_options {
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

  dynamic "instance_market_options" {
    for_each = var.use_spot_instances ? [1] : []
    content {
      market_type = "spot"
      spot_options {
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
