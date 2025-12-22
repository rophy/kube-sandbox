# Standalone Ubuntu EC2 Instance
# No K3s - just a plain Ubuntu server with 64GB RAM

locals {
  docker_userdata = <<-EOF
    #!/bin/bash
    set -e

    # Install Docker
    apt-get update
    apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add ubuntu user to docker group
    usermod -aG docker ubuntu

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker

    echo "Docker installed successfully"
  EOF
}

module "ubuntu" {
  source = "./modules/ubuntu-ec2"

  name               = var.instance_name
  instance_type      = var.instance_type
  subnet_id          = aws_subnet.public.id
  security_group_ids = [aws_security_group.main.id]
  key_name           = var.ssh_public_key != "" ? aws_key_pair.main[0].key_name : null
  use_spot           = var.use_spot
  root_volume_size   = var.root_volume_size
  user_data          = local.docker_userdata

  tags = {
    Project = "ubuntu-ec2"
  }
}
