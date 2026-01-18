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
  description = "Instance type for DB node (K3s server)"
  type        = string
  default     = "m6i.2xlarge"
}

variable "stream_instance_type" {
  description = "Instance type for Stream node (K3s agent)"
  type        = string
  default     = "m6i.2xlarge"
}

variable "client_instance_type" {
  description = "Instance type for Client node (K3s agent)"
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
