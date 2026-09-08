output "api_endpoint" {
  description = "Base URL of the backend API"
  value       = aws_apigatewayv2_api.backend.api_endpoint
}

output "jobs_table_name" {
  description = "Jobs table name"
  value       = aws_dynamodb_table.jobs.name
}

output "jobs_table_arn" {
  description = "Jobs table ARN"
  value       = aws_dynamodb_table.jobs.arn
}
