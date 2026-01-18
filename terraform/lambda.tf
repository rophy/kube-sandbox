# Lambda function for idle detection (container image based)

locals {
  # Read bucket name from backend.tfvars for Lambda environment
  backend_bucket = regex("bucket\\s*=\\s*\"([^\"]+)\"", file("${path.module}/backend.tfvars"))[0]
}

# Lambda function (container image)
resource "aws_lambda_function" "idle_checker" {
  function_name = "kube-sandbox-idle-checker"
  description   = "Checks for idle K8s cluster and runs terraform destroy"
  package_type  = "Image"
  image_uri     = var.lambda_image_uri
  timeout       = 900 # 15 minutes (Lambda max) for terraform destroy
  memory_size   = 512 # More memory for terraform operations
  role          = aws_iam_role.idle_checker.arn

  environment {
    variables = {
      LOG_GROUP_NAME       = aws_cloudwatch_log_group.flow_logs.name
      IDLE_TIMEOUT_MINUTES = var.idle_timeout_minutes
      TF_STATE_BUCKET      = local.backend_bucket
      ENABLE_AUTO_DESTROY  = var.enable_auto_destroy ? "true" : "false"
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

# EventBridge rule to run every 5 minutes
resource "aws_cloudwatch_event_rule" "idle_checker" {
  name                = "kube-sandbox-idle-checker"
  description         = "Triggers idle checker every 5 minutes"
  schedule_expression = "rate(5 minutes)"
}

# EventBridge target
resource "aws_cloudwatch_event_target" "idle_checker" {
  rule      = aws_cloudwatch_event_rule.idle_checker.name
  target_id = "idle-checker-lambda"
  arn       = aws_lambda_function.idle_checker.arn
}

# Permission for EventBridge to invoke Lambda
resource "aws_lambda_permission" "idle_checker" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.idle_checker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.idle_checker.arn
}
