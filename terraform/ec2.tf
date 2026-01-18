# Elastic IPs for stable public addresses
resource "aws_eip" "db" {
  domain = "vpc"

  tags = {
    Name = "k3s-db-eip"
  }
}

resource "aws_eip" "stream" {
  domain = "vpc"

  tags = {
    Name = "k3s-stream-eip"
  }
}

resource "aws_eip" "client" {
  domain = "vpc"

  tags = {
    Name = "k3s-client-eip"
  }
}

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

# Lambda invoke permission for auto-destroy trigger
resource "aws_iam_role_policy" "lambda_invoke" {
  name = "k3s-lambda-invoke-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = "arn:aws:lambda:*:*:function:kube-sandbox-idle-checker"
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
  # Elastic IP is known at plan time - use it directly for TLS SAN
  k3s_server_public_ip = aws_eip.db.public_ip

  k3s_server_userdata = <<-EOF
#!/bin/bash
set -e

# Install dependencies (curl-minimal already present on AL2023)
dnf install -y jq cronie
systemctl enable --now crond

# Disable firewalld (K3s manages iptables)
systemctl disable --now firewalld || true

# Elastic IP is passed from terraform - no need to fetch from metadata
PUBLIC_IP="${local.k3s_server_public_ip}"
echo "Using Elastic IP: $PUBLIC_IP"

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

# ===== NGINX SETUP FOR TLS TERMINATION =====

# Install nginx
dnf install -y nginx

# Copy K3s certs for nginx
mkdir -p /etc/nginx/ssl
cp /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt /etc/nginx/ssl/server.crt
cp /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.key /etc/nginx/ssl/server.key
cp /var/lib/rancher/k3s/server/tls/client-ca.crt /etc/nginx/ssl/client-ca.crt
cp /var/lib/rancher/k3s/server/tls/client-admin.crt /etc/nginx/ssl/client-admin.crt
cp /var/lib/rancher/k3s/server/tls/client-admin.key /etc/nginx/ssl/client-admin.key
chmod 600 /etc/nginx/ssl/*.key

# Configure nginx for K8s API proxy with client cert validation
cat > /etc/nginx/nginx.conf << 'NGINX_CONF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format k8s '$remote_addr [$time_local] "$request" $status $body_bytes_sent $ssl_client_s_dn';

    server {
        listen 16443 ssl;

        ssl_certificate /etc/nginx/ssl/server.crt;
        ssl_certificate_key /etc/nginx/ssl/server.key;
        ssl_client_certificate /etc/nginx/ssl/client-ca.crt;
        ssl_verify_client on;

        access_log /var/log/nginx/k8s-access.log k8s;

        location / {
            proxy_pass https://127.0.0.1:6443;
            proxy_ssl_certificate /etc/nginx/ssl/client-admin.crt;
            proxy_ssl_certificate_key /etc/nginx/ssl/client-admin.key;
            proxy_ssl_verify off;

            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
        }
    }
}
NGINX_CONF

systemctl enable --now nginx

# ===== IDLE CHECK CRONJOB =====

cat > /usr/local/bin/check-idle.sh << 'IDLE_CHECK'
#!/bin/bash
IDLE_MINUTES=$${IDLE_MINUTES:-${var.idle_timeout_minutes}}
LOG_FILE="/var/log/nginx/k8s-access.log"
LAMBDA_FUNCTION="kube-sandbox-idle-checker"

# Get cutoff time for idle window
CUTOFF=$(date -d "-$${IDLE_MINUTES} minutes" '+%d/%b/%Y:%H:%M')

# Count successful requests (status 200, has client cert DN) in last N minutes
RECENT_REQUESTS=$(awk -v cutoff="$${CUTOFF}" '
  {
    # Extract timestamp from log line (format: IP [dd/Mon/YYYY:HH:MM:SS +ZZZZ])
    if (match($0, /\[([0-9]+\/[A-Za-z]+\/[0-9]+:[0-9]+:[0-9]+)/, ts)) {
      timestamp = ts[1]
      # Extract status code (after "HTTP/1.1" ")
      if (match($0, /" ([0-9]+) /, st) && timestamp >= cutoff && st[1] == "200") {
        # Check if there is a client DN (not just a dash at the end)
        if (!match($0, / -$/)) {
          count++
        }
      }
    }
  }
  END { print count+0 }
' "$LOG_FILE")

echo "$(date): Checked idle status - $${RECENT_REQUESTS} requests in last $${IDLE_MINUTES} minutes"

if [ "$${RECENT_REQUESTS}" -eq 0 ]; then
    echo "Cluster idle for $${IDLE_MINUTES} minutes. Triggering destroy."
    aws lambda invoke --function-name "$LAMBDA_FUNCTION" --region $(curl -s http://169.254.169.254/latest/meta-data/placement/region) /tmp/lambda-out.json
    cat /tmp/lambda-out.json
fi
IDLE_CHECK

chmod +x /usr/local/bin/check-idle.sh

# Run every 5 minutes
echo "*/5 * * * * root /usr/local/bin/check-idle.sh >> /var/log/idle-check.log 2>&1" > /etc/cron.d/idle-check

# ===== KUBECONFIG FOR EXTERNAL ACCESS =====

# Store kubeconfig with public IP and nginx port for external access
sed -e "s/127.0.0.1/$PUBLIC_IP/g" -e "s/:6443/:16443/g" /etc/rancher/k3s/k3s.yaml > /tmp/kubeconfig-external.yaml
chmod 644 /tmp/kubeconfig-external.yaml

echo "K3s server ready with nginx proxy on port 16443"
EOF

  k3s_agent_stream_userdata = <<-EOF
#!/bin/bash
set -e

# Install dependencies (curl-minimal already present on AL2023)
dnf install -y jq cronie
systemctl enable --now crond

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
dnf install -y jq cronie
systemctl enable --now crond

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
  key_name               = aws_key_pair.main.key_name

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
  key_name               = aws_key_pair.main.key_name

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
  key_name               = aws_key_pair.main.key_name

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

# Associate Elastic IPs with instances
resource "aws_eip_association" "db" {
  instance_id   = aws_instance.db.id
  allocation_id = aws_eip.db.id
}

resource "aws_eip_association" "stream" {
  instance_id   = aws_instance.stream.id
  allocation_id = aws_eip.stream.id
}

resource "aws_eip_association" "client" {
  instance_id   = aws_instance.client.id
  allocation_id = aws_eip.client.id
}
