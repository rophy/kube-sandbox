variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-east-2"
}

variable "lambda_tf_image_uri" {
  description = "ECR image URI for apply/destroy Lambdas (Terraform image)"
  type        = string
}

variable "github_repo_url" {
  description = "GitHub repo URL for Lambda to clone terraform configs"
  type        = string
}

variable "enable_auto_destroy" {
  description = "Enable auto-destroy. When false, Lambda runs in dry-run mode."
  type        = bool
  default     = false
}
