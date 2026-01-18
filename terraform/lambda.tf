# Lambda function for idle detection

# Zip the Lambda code
data "archive_file" "idle_checker" {
  type        = "zip"
  source_file = "${path.module}/../lambda/idle_checker/main.py"
  output_path = "${path.module}/../lambda/idle_checker/main.zip"
}

# Lambda function
resource "aws_lambda_function" "idle_checker" {
  function_name    = "kube-sandbox-idle-checker"
  description      = "Checks for idle K8s cluster and triggers destroy"
  filename         = data.archive_file.idle_checker.output_path
  source_code_hash = data.archive_file.idle_checker.output_base64sha256
  handler          = "main.handler"
  runtime          = "python3.12"
  timeout          = 60
  role             = aws_iam_role.idle_checker.arn

  environment {
    variables = {
      LOG_GROUP_NAME         = aws_cloudwatch_log_group.flow_logs.name
      IDLE_TIMEOUT_MINUTES   = var.idle_timeout_minutes
      CODEBUILD_PROJECT_NAME = aws_codebuild_project.destroy.name
      ENABLE_AUTO_DESTROY    = var.enable_auto_destroy ? "true" : "false"
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
