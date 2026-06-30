# Durable buffer (ADR-002): the webhook is acked the instant the message lands here,
# independent of the app/consumer tier. Failures after max_receive_count land in the DLQ
# for redrive.

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-intake-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
  tags                      = merge(var.tags, { Name = "${var.name}-intake-dlq" })
}

resource "aws_sqs_queue" "intake" {
  name                       = "${var.name}-intake"
  visibility_timeout_seconds = max(var.lambda_timeout * 6, 30) # >= 6x consumer timeout
  message_retention_seconds  = 345600                          # 4 days
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = merge(var.tags, { Name = "${var.name}-intake" })
}

# Allow the DLQ to be redriven back to the main queue.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.intake.arn]
  })
}
