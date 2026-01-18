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

variable "master_instance_type" {
  description = "Instance type for master node (K3s server)"
  type        = string
  default     = "t3.small"
}

variable "worker1_instance_type" {
  description = "Instance type for worker1 node (K3s agent)"
  type        = string
  default     = "t3.large"
}

variable "worker2_instance_type" {
  description = "Instance type for worker2 node (K3s agent)"
  type        = string
  default     = "t3.large"
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
