output "state_machine_arn" {
  description = "ARN of the cv-processing state machine"
  value       = aws_sfn_state_machine.cv_processing.arn
}

output "alerts_topic_arn" {
  description = "SNS topic receiving the pipeline alarms"
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard of the pipeline"
  value       = aws_cloudwatch_dashboard.pipeline.dashboard_name
}
