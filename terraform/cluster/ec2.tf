# Elastic IPs for stable public addresses
resource "aws_eip" "master" {
  domain = "vpc"

  tags = {
    Name = "k3s-master-eip"
  }
}

# Worker nodes do not use Elastic IPs — they join the cluster via the master's
# private IP and rely on the subnet's auto-assigned public IPv4 for outbound
# internet (ECR pulls, yum). Use SSM Session Manager for shell access; the
# worker IAM role already includes AmazonSSMManagedInstanceCore.

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

# IAM Role for EC2
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

# EBS CSI Driver policy
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

# CloudWatch metrics permission for publishing and reading activity metrics
resource "aws_iam_role_policy" "cloudwatch_metrics" {
  name = "k3s-cloudwatch-metrics-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricStatistics"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeVpcs"]
        Resource = "*"
      }
    ]
  })
}

# ECR pull permission for container images
resource "aws_iam_role_policy" "ecr_pull" {
  name = "k3s-ecr-pull-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
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

# User data for K3s server (master node)
locals {
  k3s_server_public_ip = aws_eip.master.public_ip

  k3s_server_userdata = <<-EOF
#!/bin/bash
set -e

dnf install -y jq cronie
systemctl enable --now crond
systemctl disable --now firewalld || true

PUBLIC_IP="${local.k3s_server_public_ip}"
echo "Using Elastic IP: $PUBLIC_IP"

mkdir -p /var/lib/rancher/k3s/server/manifests

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

cat > /var/lib/rancher/k3s/server/manifests/ebs-csi-driver.yaml << 'EBSCSI'
${file("${path.module}/../../manifests/ebs-csi-driver.yaml")}
EBSCSI

cat > /var/lib/rancher/k3s/server/manifests/ebs-storageclass.yaml << 'EBSSC'
${file("${path.module}/../../manifests/ebs-storageclass.yaml")}
EBSSC

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s - \
  --token "${random_password.k3s_token.result}" \
  --disable traefik \
  --disable servicelb \
  --disable local-storage \
  --node-label "role=master" \
  --tls-san "$PUBLIC_IP" \
  --write-kubeconfig-mode 644

until kubectl get nodes; do sleep 5; done

# ===== NGINX SETUP =====
dnf install -y nginx

mkdir -p /etc/nginx/ssl
cp /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt /etc/nginx/ssl/server.crt
cp /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.key /etc/nginx/ssl/server.key
cp /var/lib/rancher/k3s/server/tls/client-ca.crt /etc/nginx/ssl/client-ca.crt
cp /var/lib/rancher/k3s/server/tls/client-admin.crt /etc/nginx/ssl/client-admin.crt
cp /var/lib/rancher/k3s/server/tls/client-admin.key /etc/nginx/ssl/client-admin.key
chmod 600 /etc/nginx/ssl/*.key

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

# ===== METRICS PUBLISHER CRONJOB =====
# Publishes K8s API request count to CloudWatch every 5 minutes
# Lambda checks these metrics to determine if cluster is idle
cat > /usr/local/bin/publish-metrics.sh << 'PUBLISH_METRICS'
#!/bin/bash
LOG_FILE="/var/log/nginx/k8s-access.log"
NAMESPACE="KubeSandbox"
METRIC_NAME="KubeApiRequests"
# IMDSv2 requires token-based access
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

# Count successful requests (status 200 with valid client cert) in last 5 minutes
CUTOFF=$(date -d "-5 minutes" '+%d/%b/%Y:%H:%M')

REQUEST_COUNT=$(awk -v cutoff="$${CUTOFF}" '
  {
    if (match($0, /\[([0-9]+\/[A-Za-z]+\/[0-9]+:[0-9]+:[0-9]+)/, ts)) {
      timestamp = ts[1]
      if (match($0, /" ([0-9]+) /, st) && timestamp >= cutoff && st[1] == "200") {
        if (!match($0, / -$/)) {
          count++
        }
      }
    }
  }
  END { print count+0 }
' "$LOG_FILE")

echo "$(date): Publishing metric - $${REQUEST_COUNT} requests in last 5 minutes"

aws cloudwatch put-metric-data \
  --namespace "$NAMESPACE" \
  --metric-name "$METRIC_NAME" \
  --value "$REQUEST_COUNT" \
  --unit Count \
  --region "$REGION"
PUBLISH_METRICS

chmod +x /usr/local/bin/publish-metrics.sh

# Cron files in /etc/cron.d/ MUST end with a newline
cat > /etc/cron.d/publish-metrics << 'CRON'
*/5 * * * * root /usr/local/bin/publish-metrics.sh >> /var/log/metrics-publish.log 2>&1

CRON

# Run metrics publisher immediately on boot (don't wait 5 minutes)
/usr/local/bin/publish-metrics.sh >> /var/log/metrics-publish.log 2>&1 &

sed -e "s/127.0.0.1/$PUBLIC_IP/g" -e "s/:6443/:16443/g" /etc/rancher/k3s/k3s.yaml > /tmp/kubeconfig-external.yaml
chmod 644 /tmp/kubeconfig-external.yaml

echo "K3s server ready with nginx proxy on port 16443"
EOF

  # Template function for worker userdata. Each worker can carry:
  #   - label: used as `role=<label>`; defaults to worker key
  #   - taint: optional `key=value:Effect` string, applied via --node-taint
  k3s_agent_userdata = { for name, cfg in var.workers : name => <<-EOF
#!/bin/bash
set -e

dnf install -y jq cronie
systemctl enable --now crond
systemctl disable --now firewalld || true

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

SERVER_IP="${aws_instance.master.private_ip}"
until curl -sk "https://$SERVER_IP:6443" >/dev/null 2>&1; do
  echo "Waiting for K3s server..."
  sleep 10
done

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent" sh -s - \
  --server "https://$SERVER_IP:6443" \
  --token "${random_password.k3s_token.result}" \
  --node-label "role=${coalesce(cfg.label, name)}"${cfg.taint != null ? " \\\n  --node-taint \"${cfg.taint}\"" : ""}

echo "K3s agent (${name}) ready"
EOF
  }
}

# Master Node - K3s Server
resource "aws_instance" "master" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.master_instance_type
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
    volume_size = 30
    volume_type = "gp3"
  }

  tags = {
    Name = "k3s-master"
    Role = "server"
  }
}

# Worker Nodes - K3s Agents
resource "aws_instance" "worker" {
  for_each               = var.workers
  ami                    = data.aws_ami.al2023.id
  instance_type          = each.value.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.k3s.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = aws_key_pair.main.key_name

  user_data = local.k3s_agent_userdata[each.key]

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

  depends_on = [aws_instance.master]

  tags = {
    Name = "k3s-${each.key}"
    Role = "agent"
  }
}

# Associate Elastic IPs with instances
resource "aws_eip_association" "master" {
  instance_id   = aws_instance.master.id
  allocation_id = aws_eip.master.id
}

