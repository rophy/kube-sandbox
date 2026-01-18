# Shared IAM role for all Lambda functions

resource "aws_iam_role" "lambda" {
  name = "kube-sandbox-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# Basic Lambda execution (CloudWatch Logs)
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# AdministratorAccess for terraform operations (dedicated sandbox account)
resource "aws_iam_role_policy_attachment" "lambda_admin" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Allow check Lambda to invoke destroy Lambda
resource "aws_iam_role_policy" "lambda_invoke" {
  name = "kube-sandbox-lambda-invoke"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = "arn:aws:lambda:*:*:function:kube-sandbox-*"
    }]
  })
}

# Allow check Lambda to read CloudWatch metrics
resource "aws_iam_role_policy" "cloudwatch_metrics" {
  name = "kube-sandbox-cloudwatch-metrics"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:GetMetricData"
      ]
      Resource = "*"
    }]
  })
}
