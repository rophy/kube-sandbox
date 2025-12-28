# Get available AZs
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az = var.availability_zone != "" ? var.availability_zone : data.aws_availability_zones.available.names[0]
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name                      = "k3s-perf-test-vpc"
    "kube-sandbox/created-at" = timestamp()
  }

  lifecycle {
    ignore_changes = [tags["kube-sandbox/created-at"]]
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "k3s-perf-test-igw"
  }
}

# Public Subnet (single AZ, no NAT Gateway)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = true

  tags = {
    Name = "k3s-perf-test-public"
  }
}

# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "k3s-perf-test-rt"
  }
}

# Route Table Association
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
