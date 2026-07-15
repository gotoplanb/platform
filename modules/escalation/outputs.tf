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
  description = "On-call/KPI alarm (missed escalation OR engine error) — attach an SNS action in #11. NOT the deploy gate (ADR-048)."
  value       = aws_cloudwatch_metric_alarm.executions_failed.arn
}

output "executions_failed_alarm_name" {
  description = "On-call/KPI alarm name (ADR-001). NOT the deploy gate — see engine_error_alarm_name."
  value       = aws_cloudwatch_metric_alarm.executions_failed.alarm_name
}

output "engine_error_alarm_arn" {
  description = "Deploy-gate alarm (LambdaFunctionsFailed) — CodeDeploy auto-rollback (ADR-048)."
  value       = aws_cloudwatch_metric_alarm.engine_error.arn
}

output "engine_error_alarm_name" {
  description = "Deploy-gate alarm name for CodeDeploy rollback_alarm_names (ADR-048)."
  value       = aws_cloudwatch_metric_alarm.engine_error.alarm_name
}
