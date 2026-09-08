output "cluster_arn" {
  description = "Aurora cluster ARN (Data API resourceArn)"
  value       = aws_rds_cluster.vectorstore.arn
}

output "secret_arn" {
  description = "RDS-managed master secret ARN (Data API secretArn)"
  value       = aws_rds_cluster.vectorstore.master_user_secret[0].secret_arn
}

output "database_name" {
  description = "Database name"
  value       = aws_rds_cluster.vectorstore.database_name
}
