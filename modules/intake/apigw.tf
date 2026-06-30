# HTTP API: POST /webhook -> (authorizer checks the shared secret) -> direct SQS
# SendMessage. No Lambda in the ingest path, so capture survives app/consumer impairment
# (ADR-002): the source is acked the moment SQS accepts the message.

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name}-intake"
  protocol_type = "HTTP"
  tags          = merge(var.tags, { Name = "${var.name}-intake" })
}

# API Gateway -> SQS:SendMessage credential.
data "aws_iam_policy_document" "apigw_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw" {
  name               = "${var.name}-intake-apigw"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "apigw_sqs" {
  name = "${var.name}-intake-apigw"
  role = aws_iam_role.apigw.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.intake.arn
    }]
  })
}

resource "aws_apigatewayv2_integration" "sqs" {
  api_id              = aws_apigatewayv2_api.this.id
  integration_type    = "AWS_PROXY"
  integration_subtype = "SQS-SendMessage"
  credentials_arn     = aws_iam_role.apigw.arn

  request_parameters = {
    QueueUrl    = aws_sqs_queue.intake.url
    MessageBody = "$request.body"
  }

  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_authorizer" "secret" {
  api_id                            = aws_apigatewayv2_api.this.id
  authorizer_type                   = "REQUEST"
  name                              = "${var.name}-webhook-secret"
  authorizer_uri                    = aws_lambda_function.authorizer.invoke_arn
  identity_sources                  = ["$request.header.X-Watch-Webhook-Secret"]
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  authorizer_result_ttl_in_seconds  = 60
}

resource "aws_lambda_permission" "authorizer" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.secret.id}"
}

resource "aws_apigatewayv2_route" "webhook" {
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = "POST /webhook"
  target             = "integrations/${aws_apigatewayv2_integration.sqs.id}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.secret.id
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/apigw/${var.name}-intake"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId    = "$context.requestId"
      routeKey     = "$context.routeKey"
      status       = "$context.status"
      sourceIp     = "$context.identity.sourceIp"
      responseTime = "$context.responseLatency"
      authError    = "$context.authorizer.error"
    })
  }

  tags = var.tags
}
