# Get available AZs
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Primary AZ — master's home, and fallback for workers that don't set `az`.
  az = var.availability_zone != "" ? var.availability_zone : data.aws_availability_zones.available.names[0]

  # All AZs to create subnets in. Empty var.availability_zones collapses to single-AZ (primary only).
  azs = length(var.availability_zones) > 0 ? var.availability_zones : [local.az]

  # /24 subnet per AZ carved from var.vpc_cidr (supports up to 256 AZs; practically region-limited).
  # Using idx+1 so single-AZ default remains 10.0.1.0/24 to match previous behavior.
  subnet_cidrs = { for idx, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, idx + 1) }
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
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "k3s-perf-test-igw"
  }
}

# Public Subnet — one per AZ in local.azs
resource "aws_subnet" "public" {
  for_each                = toset(local.azs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.subnet_cidrs[each.key]
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = {
    Name = "k3s-perf-test-public-${each.key}"
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

# Route Table Association — one per subnet
resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
