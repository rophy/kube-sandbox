output "check_function_name" {
  description = "Name of the check Lambda function"
  value       = aws_lambda_function.check.function_name
}

output "destroy_function_name" {
  description = "Name of the destroy Lambda function"
  value       = aws_lambda_function.destroy.function_name
}

output "apply_function_name" {
  description = "Name of the apply Lambda function"
  value       = aws_lambda_function.apply.function_name
}

output "eventbridge_rule" {
  description = "EventBridge rule for scheduled checks"
  value       = aws_cloudwatch_event_rule.check_schedule.name
}
