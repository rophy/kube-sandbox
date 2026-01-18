# Lambda function for auto-destroy (triggered by EC2 cronjob when idle)

locals {
  # Read bucket name from backend.tfvars for Lambda environment
  backend_bucket = regex("bucket\\s*=\\s*\"([^\"]+)\"", file("${path.module}/backend.tfvars"))[0]
}

# Lambda function (container image)
# Triggered on-demand by EC2 cronjob when cluster is idle - no periodic schedule
resource "aws_lambda_function" "idle_checker" {
  function_name = "kube-sandbox-idle-checker"
  description   = "Runs terraform destroy when triggered by EC2 idle detection"
  package_type  = "Image"
  image_uri     = var.lambda_image_uri
  timeout       = 900 # 15 minutes (Lambda max) for terraform destroy
  memory_size   = 512 # More memory for terraform operations
  role          = aws_iam_role.idle_checker.arn

  ephemeral_storage {
    size = 1024 # 1GB for terraform providers (AWS provider alone is ~400MB)
  }

  environment {
    variables = {
      GITHUB_REPO_URL     = var.github_repo_url
      TF_STATE_BUCKET     = local.backend_bucket
      ENABLE_AUTO_DESTROY = var.enable_auto_destroy ? "true" : "false"
    }
  }

  tags = {
    Name = "kube-sandbox-idle-checker"
  }
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "idle_checker" {
  name              = "/aws/lambda/kube-sandbox-idle-checker"
  retention_in_days = 7
}
