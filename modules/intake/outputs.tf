output "webhook_url" {
  description = "POST here with the X-Watch-Webhook-Secret header (the #13 DNS can front it)."
  value       = "${aws_apigatewayv2_api.this.api_endpoint}/webhook"
}

output "api_id" {
  value = aws_apigatewayv2_api.this.id
}

output "queue_url" {
  value = aws_sqs_queue.intake.url
}

output "queue_arn" {
  value = aws_sqs_queue.intake.arn
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}

output "consumer_function_name" {
  description = "The pipeline (#10) updates this function's code."
  value       = aws_lambda_function.consumer.function_name
}

output "authorizer_function_name" {
  value = aws_lambda_function.authorizer.function_name
}
