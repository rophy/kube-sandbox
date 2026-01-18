terraform {
  required_version = ">= 1.0"

  backend "s3" {
    key          = "kube-sandbox/infra/terraform.tfstate"
    region       = "ap-east-2"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "kube-sandbox"
      Component   = "infra"
      ManagedBy   = "terraform"
    }
  }
}
