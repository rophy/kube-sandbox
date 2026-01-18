# IAM roles for auto-destroy (CodeBuild and Lambda)

# =============================================================================
# CodeBuild IAM Role
# =============================================================================

resource "aws_iam_role" "codebuild" {
  name = "kube-sandbox-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "codebuild.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# AdministratorAccess for CodeBuild (dedicated sandbox account, simplicity over least-privilege)
resource "aws_iam_role_policy_attachment" "codebuild_admin" {
  role       = aws_iam_role.codebuild.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# =============================================================================
# Lambda IAM Role
# =============================================================================

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

# Custom policy for idle checker
resource "aws_iam_role_policy" "idle_checker" {
  name = "kube-sandbox-idle-checker-policy"
  role = aws_iam_role.idle_checker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:StartQuery",
          "logs:GetQueryResults",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild"
        ]
        Resource = aws_codebuild_project.destroy.arn
      }
    ]
  })
}
