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

output "vectorstore_cluster_arn" {
  value = module.vectorstore.cluster_arn
}

output "vectorstore_secret_arn" {
  value = module.vectorstore.secret_arn
}
