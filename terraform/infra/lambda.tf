# Lambda functions for cluster management
# All use same Docker image, different handlers

variable "tf_state_bucket" {
  description = "S3 bucket for terraform state"
  type        = string
}

variable "idle_threshold_minutes" {
  description = "Minutes of inactivity before triggering destroy"
  type        = number
  default     = 30
}

variable "check_interval_minutes" {
  description = "How often to check for idle cluster"
  type        = number
  default     = 5
}

locals {
  common_env = {
    GITHUB_REPO_URL = var.github_repo_url
    TF_STATE_BUCKET = var.tf_state_bucket
  }
}

# ===== CHECK Lambda =====
# Runs on schedule, checks CloudWatch metrics, invokes destroy if idle

resource "aws_lambda_function" "check" {
  function_name = "kube-sandbox-check"
  description   = "Check cluster activity metrics, trigger destroy if idle"
  package_type  = "Image"
  image_uri     = var.lambda_api_image_uri
  timeout       = 60
  memory_size   = 256
  role          = aws_iam_role.lambda.arn

  environment {
    variables = merge(local.common_env, {
      ENABLE_AUTO_DESTROY    = var.enable_auto_destroy ? "true" : "false"
      IDLE_THRESHOLD_MINUTES = tostring(var.idle_threshold_minutes)
      CHECK_INTERVAL_MINUTES = tostring(var.check_interval_minutes)
      DESTROY_FUNCTION_NAME  = "kube-sandbox-destroy"
    })
  }

  tags = {
    Name = "kube-sandbox-check"
  }
}

# EventBridge rule to trigger check every N minutes
resource "aws_cloudwatch_event_rule" "check_schedule" {
  name                = "kube-sandbox-check-schedule"
  description         = "Trigger cluster idle check"
  schedule_expression = "rate(${var.check_interval_minutes} minutes)"
}

resource "aws_cloudwatch_event_target" "check_lambda" {
  rule      = aws_cloudwatch_event_rule.check_schedule.name
  target_id = "check-lambda"
  arn       = aws_lambda_function.check.arn
}

resource "aws_lambda_permission" "check_eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.check.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.check_schedule.arn
}

# ===== DESTROY Lambda =====
# Runs terraform destroy on cluster

resource "aws_lambda_function" "destroy" {
  function_name = "kube-sandbox-destroy"
  description   = "Destroy cluster with terraform"
  package_type  = "Image"
  image_uri     = var.lambda_tf_image_uri
  timeout       = 900 # 15 minutes for terraform destroy
  memory_size   = 512
  role          = aws_iam_role.lambda.arn

  ephemeral_storage {
    size = 1024 # 1GB for terraform providers
  }

  environment {
    variables = merge(local.common_env, {
      TF_ACTION = "destroy"
    })
  }

  tags = {
    Name = "kube-sandbox-destroy"
  }
}

# ===== APPLY Lambda =====
# Runs terraform apply on cluster (for future automation)

resource "aws_lambda_function" "apply" {
  function_name = "kube-sandbox-apply"
  description   = "Create cluster with terraform"
  package_type  = "Image"
  image_uri     = var.lambda_tf_image_uri
  timeout       = 900 # 15 minutes for terraform apply
  memory_size   = 512
  role          = aws_iam_role.lambda.arn

  ephemeral_storage {
    size = 1024
  }

  environment {
    variables = merge(local.common_env, {
      TF_ACTION = "apply"
    })
  }

  tags = {
    Name = "kube-sandbox-apply"
  }
}

# ===== CloudWatch Log Groups =====

resource "aws_cloudwatch_log_group" "check" {
  name              = "/aws/lambda/kube-sandbox-check"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "destroy" {
  name              = "/aws/lambda/kube-sandbox-destroy"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "apply" {
  name              = "/aws/lambda/kube-sandbox-apply"
  retention_in_days = 7
}
