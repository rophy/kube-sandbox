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

variable "instance_name" {
  description = "Name for the EC2 instance"
  type        = string
  default     = "ubuntu-server"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "r7i.2xlarge"
}

variable "use_spot" {
  description = "Use spot instances for cost savings"
  type        = bool
  default     = false
}

variable "root_volume_size" {
  description = "Root volume size in GB"
  type        = number
  default     = 200
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
