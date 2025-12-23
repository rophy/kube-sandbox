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
  default     = "r6i.large"
}

variable "stream_instance_type" {
  description = "Instance type for node 2 (K3s agent)"
  type        = string
  default     = "c6i.large"
}

variable "client_instance_type" {
  description = "Instance type for node 3 (K3s agent)"
  type        = string
  default     = "c6i.large"
}

variable "use_spot_instances" {
  description = "Use spot instances for cost savings"
  type        = bool
  default     = false
}

variable "ssh_public_key" {
  description = "SSH public key for EC2 access (optional)"
  type        = string
  default     = ""
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed for SSH access"
  type        = string
  default     = "0.0.0.0/0"
}
