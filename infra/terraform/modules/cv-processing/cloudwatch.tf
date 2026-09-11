##observability (doc 7/9): few ACTIONABLE alarms — the rest is
##dashboard. Alarm destinations go to an SNS topic; subscriptions
##(email/chat) are attached out-of-band.

resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"
}

##--- alarms ----------------------------------------------------------

##a non-empty DLQ means a CV did not make it into the pipeline
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${var.name_prefix}-dlq-not-empty"
  alarm_description   = "cv-events DLQ has messages: a CV failed all delivery attempts"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.cv_events_dlq.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "sfn_failed" {
  alarm_name          = "${var.name_prefix}-pipeline-executions-failed"
  alarm_description   = "cv-processing executions failed (job status FAILED holds the cause)"
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  dimensions          = { StateMachineArn = aws_sfn_state_machine.cv_processing.arn }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

##breaker open = the external employer source is down (doc 5.3)
resource "aws_cloudwatch_metric_alarm" "breaker_opened" {
  alarm_name          = "${var.name_prefix}-breaker-opened"
  alarm_description   = "Employer source circuit breaker opened"
  namespace           = "SkillBridge/Pipeline"
  metric_name         = "BreakerOpened"
  dimensions          = { Step = "agent-matching" }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

##a spike of failed sanity checks = the parser (or the input mix) broke
resource "aws_cloudwatch_metric_alarm" "sanity_check_rate" {
  alarm_name          = "${var.name_prefix}-sanity-check-failures"
  alarm_description   = "Parsing sanity checks failing above threshold in the last hour"
  namespace           = "SkillBridge/Pipeline"
  metric_name         = "SanityCheckFailed"
  dimensions          = { Step = "parse-cv" }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

##cost as an anomaly signal (doc 9): sudden growth flags a grown
##prompt or a loop before any human complaint. Aggregate (no-dimension)
##series across all steps
resource "aws_cloudwatch_metric_alarm" "hourly_cost" {
  alarm_name          = "${var.name_prefix}-pipeline-hourly-cost"
  alarm_description   = "Bedrock spend (EUR) of the pipeline above threshold in the last hour"
  namespace           = "SkillBridge/Pipeline"
  metric_name         = "StepCostEur"
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = var.hourly_cost_alarm_eur
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

##--- dashboard --------------------------------------------------------

resource "aws_cloudwatch_dashboard" "pipeline" {
  dashboard_name = "${var.name_prefix}-pipeline"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Executions"
          region = "eu-central-1"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", aws_sfn_state_machine.cv_processing.arn],
            [".", "ExecutionsFailed", ".", "."],
            [".", "ExecutionsStarted", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Cost per step (EUR)"
          region = "eu-central-1"
          stat   = "Sum"
          period = 300
          metrics = [
            for step in ["parse-cv", "redact-pii", "guardrail", "normalize-skills", "chunk-cv", "embed-cv", "agent-matching"] :
            ["SkillBridge/Pipeline", "StepCostEur", "Step", step]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Tokens (in/out, all steps)"
          region = "eu-central-1"
          stat   = "Sum"
          period = 300
          metrics = [
            ["SkillBridge/Pipeline", "TokensIn"],
            [".", "TokensOut"],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Agent outcomes"
          region = "eu-central-1"
          stat   = "Sum"
          period = 300
          metrics = [
            ["SkillBridge/Pipeline", "Outcome_match", "Step", "agent-matching"],
            [".", "Outcome_no_match", ".", "."],
            [".", "Outcome_not_verifiable", ".", "."],
            [".", "BudgetExhausted", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "Quality signals"
          region = "eu-central-1"
          stat   = "Sum"
          period = 300
          metrics = [
            ["SkillBridge/Pipeline", "SanityCheckFailed", "Step", "parse-cv"],
            [".", "FlaggedSpans", "Step", "guardrail"],
            [".", "SkillsUnmatched", "Step", "normalize-skills"],
            [".", "PiiCount", "Step", "redact-pii"],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6
        properties = {
          title  = "DLQ depth"
          region = "eu-central-1"
          stat   = "Maximum"
          period = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.cv_events_dlq.name],
          ]
        }
      },
    ]
  })
}
