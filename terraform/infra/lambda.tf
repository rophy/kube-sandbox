# Lambda functions for cluster management

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

variable "grace_period_minutes" {
  description = "Minutes after cluster creation before idle checks start"
  type        = number
  default     = 10
}

locals {
  common_env = {
    GITHUB_REPO_URL = var.github_repo_url
    TF_STATE_BUCKET = var.tf_state_bucket
  }

  status_env = {
    IDLE_THRESHOLD_MINUTES = tostring(var.idle_threshold_minutes)
    CHECK_INTERVAL_MINUTES = tostring(var.check_interval_minutes)
    GRACE_PERIOD_MINUTES   = tostring(var.grace_period_minutes)
  }
}

# ===== Status Lambda (Node.js, zip deployment) =====
# Shared code for check and status handlers

data "archive_file" "status_lambda" {
  type        = "zip"
  source_file = "${path.module}/../../lambda/status.mjs"
  output_path = "${path.module}/../../.build/status_lambda.zip"
}

# Check Lambda - scheduled invocation
resource "aws_lambda_function" "check" {
  function_name                  = "kube-sandbox-check"
  description                    = "Check cluster activity, trigger destroy if idle"
  filename                       = data.archive_file.status_lambda.output_path
  source_code_hash               = data.archive_file.status_lambda.output_base64sha256
  handler                        = "status.checkHandler"
  runtime                        = "nodejs22.x"
  timeout                        = 60
  memory_size                    = 128
  reserved_concurrent_executions = 1
  role                           = aws_iam_role.lambda.arn

  environment {
    variables = merge(local.status_env, {
      ENABLE_AUTO_DESTROY   = var.enable_auto_destroy ? "true" : "false"
      DESTROY_FUNCTION_NAME = "kube-sandbox-destroy"
    })
  }

  tags = {
    Name = "kube-sandbox-check"
  }
}

# Status Lambda - API Gateway handler
resource "aws_lambda_function" "status" {
  function_name                  = "kube-sandbox-status"
  description                    = "Return cluster status via API Gateway"
  filename                       = data.archive_file.status_lambda.output_path
  source_code_hash               = data.archive_file.status_lambda.output_base64sha256
  handler                        = "status.statusHandler"
  runtime                        = "nodejs22.x"
  timeout                        = 30
  memory_size                    = 128
  reserved_concurrent_executions = 1
  role                           = aws_iam_role.lambda.arn

  environment {
    variables = local.status_env
  }

  tags = {
    Name = "kube-sandbox-status"
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

# ===== API Gateway (REST API) =====

resource "aws_api_gateway_rest_api" "status" {
  name        = "kube-sandbox-status"
  description = "Kube Sandbox Status API"
}

resource "aws_api_gateway_resource" "status" {
  rest_api_id = aws_api_gateway_rest_api.status.id
  parent_id   = aws_api_gateway_rest_api.status.root_resource_id
  path_part   = "status"
}

resource "aws_api_gateway_method" "status_get" {
  rest_api_id   = aws_api_gateway_rest_api.status.id
  resource_id   = aws_api_gateway_resource.status.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "status" {
  rest_api_id             = aws_api_gateway_rest_api.status.id
  resource_id             = aws_api_gateway_resource.status.id
  http_method             = aws_api_gateway_method.status_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.status.invoke_arn
}

resource "aws_api_gateway_deployment" "status" {
  rest_api_id = aws_api_gateway_rest_api.status.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.status.id,
      aws_api_gateway_method.status_get.id,
      aws_api_gateway_integration.status.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.status.id
  rest_api_id   = aws_api_gateway_rest_api.status.id
  stage_name    = "prod"
}

resource "aws_lambda_permission" "status_apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.status.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.status.execution_arn}/*/*"
}

# ===== DESTROY Lambda (Container, terraform) =====

resource "aws_lambda_function" "destroy" {
  function_name                  = "kube-sandbox-destroy"
  description                    = "Destroy cluster with terraform"
  package_type                   = "Image"
  image_uri                      = var.lambda_tf_image_uri
  timeout                        = 900
  memory_size                    = 512
  reserved_concurrent_executions = 1
  role                           = aws_iam_role.lambda.arn

  ephemeral_storage {
    size = 1024
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

# ===== APPLY Lambda (Container, terraform) =====

resource "aws_lambda_function" "apply" {
  function_name                  = "kube-sandbox-apply"
  description                    = "Create cluster with terraform"
  package_type                   = "Image"
  image_uri                      = var.lambda_tf_image_uri
  timeout                        = 900
  memory_size                    = 512
  reserved_concurrent_executions = 1
  role                           = aws_iam_role.lambda.arn

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

resource "aws_cloudwatch_log_group" "status" {
  name              = "/aws/lambda/kube-sandbox-status"
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

# ===== Outputs =====

output "status_api_url" {
  description = "URL for the status API"
  value       = "${aws_api_gateway_stage.prod.invoke_url}/status"
}
