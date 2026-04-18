variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "availability_zone" {
  description = "Primary AZ — used for master and workers without an explicit `az`. Leave empty for auto-selection (first available)."
  type        = string
  default     = ""
}

variable "availability_zones" {
  description = "AZs to create subnets in. Empty = single-AZ (uses var.availability_zone only). Non-empty = multi-AZ; each worker can pin to an AZ via its `az` field."
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "VPC CIDR block. Per-AZ /24 subnets are carved from this via cidrsubnet(vpc_cidr, 8, idx+1)."
  type        = string
  default     = "10.0.0.0/16"
}

variable "master_instance_type" {
  description = "Instance type for master node. Leave empty to auto-select based on worker count: ≤5 → t3.small, ≤20 → t3.medium, >20 → t3.xlarge."
  type        = string
  default     = ""
}

variable "workers" {
  description = "Map of worker nodes. label → value for `role=<label>`; taint → optional `key=value:Effect` string; az → optional AZ pin (must be in var.availability_zones, defaults to primary AZ)."
  type = map(object({
    instance_type = string
    label         = optional(string)
    taint         = optional(string)
    az            = optional(string)
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
