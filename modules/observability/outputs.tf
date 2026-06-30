output "alb_5xx_alarm_name" {
  description = "Add to the deploy gate's rollback alarms (#10)."
  value       = aws_cloudwatch_metric_alarm.elb_5xx.alarm_name
}

output "target_5xx_alarm_name" {
  value = aws_cloudwatch_metric_alarm.target_5xx.alarm_name
}

output "alarm_names" {
  description = "All deploy-gate alarms from this stack."
  value       = [aws_cloudwatch_metric_alarm.elb_5xx.alarm_name, aws_cloudwatch_metric_alarm.target_5xx.alarm_name]
}
