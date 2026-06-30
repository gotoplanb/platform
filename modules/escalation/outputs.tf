output "state_machine_arn" {
  description = "Escalation state machine ARN (the app predicts this from name; matches)."
  value       = aws_sfn_state_machine.this.arn
}

output "state_machine_name" {
  value = aws_sfn_state_machine.this.name
}

output "record_token_function_arn" {
  value = aws_lambda_function.record_token.arn
}

output "commit_function_arn" {
  value = aws_lambda_function.commit.arn
}

output "lambda_role_arn" {
  value = aws_iam_role.lambda.arn
}

output "executions_failed_alarm_arn" {
  description = "Alarm to attach an SNS action to in #11."
  value       = aws_cloudwatch_metric_alarm.executions_failed.arn
}

output "executions_failed_alarm_name" {
  description = "Alarm name for the deploy gate (#10)."
  value       = aws_cloudwatch_metric_alarm.executions_failed.alarm_name
}
