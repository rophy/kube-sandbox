variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-east-2"
}

variable "availability_zone" {
  description = "Availability zone (leave empty for auto-selection)"
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "Subnet CIDR block"
  type        = string
  default     = "10.0.1.0/24"
}

variable "db_instance_type" {
  description = "Instance type for node 1 (K3s server)"
  type        = string
  default     = "m6i.2xlarge"
}

variable "stream_instance_type" {
  description = "Instance type for node 2 (K3s agent)"
  type        = string
  default     = "m6i.2xlarge"
}

variable "client_instance_type" {
  description = "Instance type for node 3 (K3s agent)"
  type        = string
  default     = "m6i.2xlarge"
}

variable "use_spot_instances" {
  description = "Use spot instances for cost savings"
  type        = bool
  default     = false
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed for SSH access"
  type        = string
  default     = "0.0.0.0/0"
}

variable "idle_timeout_minutes" {
  description = "Minutes of idle before auto-destroy"
  type        = number
  default     = 30
}

variable "enable_auto_destroy" {
  description = "Enable auto-destroy on idle. When false, Lambda logs idle detection but doesn't trigger destroy (dry-run mode for testing)."
  type        = bool
  default     = false
}

variable "lambda_image_uri" {
  description = "ECR image URI for the idle-checker Lambda (e.g., 123456789.dkr.ecr.ap-east-2.amazonaws.com/kube-sandbox-lambda:0.1.0)"
  type        = string
}
