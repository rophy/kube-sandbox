# IAM role for Lambda auto-destroy

resource "aws_iam_role" "idle_checker" {
  name = "kube-sandbox-idle-checker-role"

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

# Basic Lambda execution (CloudWatch Logs for Lambda's own logs)
resource "aws_iam_role_policy_attachment" "idle_checker_basic" {
  role       = aws_iam_role.idle_checker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# AdministratorAccess for terraform destroy (dedicated sandbox account, simplicity over least-privilege)
resource "aws_iam_role_policy_attachment" "idle_checker_admin" {
  role       = aws_iam_role.idle_checker.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
