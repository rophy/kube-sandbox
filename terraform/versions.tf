terraform {
  required_version = ">= 1.0"

  backend "s3" {
    bucket       = "rophy-tf-states"
    key          = "kube-sandbox/terraform.tfstate"
    region       = "ap-east-2"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "k3s-perf-test"
      Environment = "ephemeral"
      ManagedBy   = "terraform"
    }
  }
}
