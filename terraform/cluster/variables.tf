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

variable "workers" {
  description = "Map of worker nodes. label → value for `role=<label>`; taint → optional `key=value:Effect` string."
  type = map(object({
    instance_type = string
    label         = optional(string)
    taint         = optional(string)
  }))
  default = {
    worker1 = { instance_type = "t3.large", label = "worker1" }
    worker2 = { instance_type = "t3.large", label = "worker2" }
    worker3 = { instance_type = "t3.large", label = "worker3" }
  }
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
