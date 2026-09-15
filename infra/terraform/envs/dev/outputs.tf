##output names are consumed by the deploy pipelines: keep them stable

##used as VITE_API_BASE_URL in the frontend build
output "api_base_url" {
  value = module.backend_api.api_endpoint
}

output "fe_bucket" {
  value = module.frontend.bucket
}

output "fe_distribution_id" {
  value = module.frontend.distribution_id
}

output "fe_url" {
  value = module.frontend.url
}

output "cv_processing_state_machine_arn" {
  value = module.cv_processing.state_machine_arn
}

##consumed by the frontend build (VITE_COGNITO_*) and by admin
##user creation
output "cognito_user_pool_id" {
  value = module.auth.user_pool_id
}

output "cognito_client_id" {
  value = module.auth.client_id
}

output "cognito_domain" {
  value = module.auth.hosted_ui_domain
}

output "vectorstore_cluster_arn" {
  value = module.vectorstore.cluster_arn
}

output "vectorstore_secret_arn" {
  value = module.vectorstore.secret_arn
}

output "alerts_topic_arn" {
  value = module.cv_processing.alerts_topic_arn
}

output "dashboard_name" {
  value = module.cv_processing.dashboard_name
}
