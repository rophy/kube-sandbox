# CodeBuild project for auto-destroy

locals {
  # Read bucket name from backend.tfvars
  backend_bucket = regex("bucket\\s*=\\s*\"([^\"]+)\"", file("${path.module}/backend.tfvars"))[0]
}

resource "aws_codebuild_project" "destroy" {
  name          = "kube-sandbox-destroy"
  description   = "Destroys kube-sandbox infrastructure when idle"
  build_timeout = 60 # minutes
  service_role  = aws_iam_role.codebuild.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "TF_STATE_BUCKET"
      value = local.backend_bucket
    }
  }

  source {
    type            = "GITHUB"
    location        = "https://github.com/rophy/kube-sandbox.git"
    git_clone_depth = 1
    buildspec       = "buildspec.yml"
  }

  source_version = "main"

  logs_config {
    cloudwatch_logs {
      group_name  = "/kube-sandbox/codebuild"
      stream_name = "destroy"
    }
  }

  tags = {
    Name = "kube-sandbox-destroy"
  }
}

# CloudWatch Log Group for CodeBuild
resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/kube-sandbox/codebuild"
  retention_in_days = 7
}
