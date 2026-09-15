output "user_pool_id" {
  description = "Cognito user pool id (admin user creation)"
  value       = aws_cognito_user_pool.users.id
}

output "client_id" {
  description = "SPA app client id (public identifier)"
  value       = aws_cognito_user_pool_client.spa.id
}

output "issuer_url" {
  description = "JWT issuer URL (validated by the API Gateway authorizer)"
  value       = "https://cognito-idp.eu-central-1.amazonaws.com/${aws_cognito_user_pool.users.id}"
}

output "hosted_ui_domain" {
  description = "Hosted UI login domain"
  value       = "https://${aws_cognito_user_pool_domain.users.domain}.auth.eu-central-1.amazoncognito.com"
}
