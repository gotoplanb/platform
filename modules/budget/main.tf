# AWS Budgets cost guardrail (a daily/monthly spend threshold with email alerts). Budgets
# — not a CloudWatch billing alarm — because CloudWatch's EstimatedCharges metric is
# month-to-date cumulative; a *daily* "did we overspend today" needs a DAILY budget.
# Reusable: amount + period + an optional cost filter (e.g. per-env via the env tag).

variable "name" {
  description = "Budget name, e.g. watch-daily-cost or watch-prod-daily."
  type        = string
}

variable "amount" {
  description = "Limit in USD (placeholder default $10)."
  type        = number
  default     = 10
}

variable "time_unit" {
  description = "DAILY | MONTHLY | QUARTERLY | ANNUALLY."
  type        = string
  default     = "DAILY"
}

variable "notification_emails" {
  description = "Who gets alerted when a threshold is crossed."
  type        = list(string)
}

variable "thresholds" {
  description = "Percent-of-limit thresholds to alert at (ACTUAL spend)."
  type        = list(number)
  default     = [80, 100]
}

variable "cost_filters" {
  description = "Optional Budgets cost filters, e.g. { TagKeyValue = [\"user:env$prod\"] } to scope to one environment."
  type        = map(list(string))
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_budgets_budget" "this" {
  name         = var.name
  budget_type  = "COST"
  limit_amount = tostring(var.amount)
  limit_unit   = "USD"
  time_unit    = var.time_unit

  dynamic "cost_filter" {
    for_each = var.cost_filters
    content {
      name   = cost_filter.key
      values = cost_filter.value
    }
  }

  dynamic "notification" {
    for_each = toset(var.thresholds)
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.notification_emails
    }
  }
}

output "budget_name" {
  value = aws_budgets_budget.this.name
}
