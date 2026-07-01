# Persistent CodeConnections (GitHub) connection (platform#33). Lives in its OWN stack so it
# survives teardown/recreate: authorized ONCE (the browser handshake), then AVAILABLE for
# every future pipeline. This is what makes the #24 push trigger register — CodePipeline only
# establishes the trigger's event subscription when the pipeline is created with an already
# AVAILABLE connection, which a lifecycle-coupled connection (recreated PENDING each time)
# can never guarantee.

variable "name" {
  description = "Connection name (<=32 chars), e.g. watch-github."
  type        = string
}

variable "provider_type" {
  description = "GitHub | GitHubEnterpriseServer | Bitbucket | GitLab."
  type        = string
  default     = "GitHub"
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_codestarconnections_connection" "this" {
  name          = substr(var.name, 0, 32)
  provider_type = var.provider_type
  tags          = var.tags

  # The connection is created PENDING and authorized once by hand; never let a plan churn it.
  lifecycle {
    prevent_destroy = true
  }
}

output "connection_arn" {
  description = "ARN consumed by the pipeline stack's source action + IAM."
  value       = aws_codestarconnections_connection.this.arn
}

output "connection_status" {
  value = aws_codestarconnections_connection.this.connection_status
}
