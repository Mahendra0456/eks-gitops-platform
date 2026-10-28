variable "alert_email" {
  description = "Email address that receives budget and anomaly alerts"
  type        = string
}

variable "budget_usd" {
  description = "Monthly budget in USD"
  type        = string
  default     = "25"
}

data "aws_caller_identity" "current" {}

resource "aws_budgets_budget" "monthly" {
  name         = "ecom-monthly-budget"
  budget_type  = "COST"
  limit_amount = var.budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# A custom monitor on this account. (AWS allows only one "AWS services" monitor
# per account and it may already exist, so a custom monitor avoids that clash.)
resource "aws_ce_anomaly_monitor" "account" {
  name         = "ecom-account-monitor"
  monitor_type = "CUSTOM"

  monitor_specification = jsonencode({
    And            = null
    CostCategories = null
    Dimensions = {
      Key          = "LINKED_ACCOUNT"
      MatchOptions = null
      Values       = [data.aws_caller_identity.current.account_id]
    }
    Not  = null
    Or   = null
    Tags = null
  })
}

resource "aws_ce_anomaly_subscription" "alerts" {
  name             = "ecom-anomaly-alerts"
  frequency        = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.account.arn]

  subscriber {
    type    = "EMAIL"
    address = var.alert_email
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = ["5"]
    }
  }
}

output "monitor_arn" {
  value = aws_ce_anomaly_monitor.account.arn
}
