variable "name_prefix" {
  description = "Resource name prefix (project-environment)"
  type        = string
}

variable "cv_bucket_id" {
  description = "Name/id of the CV bucket"
  type        = string
}

variable "cv_bucket_arn" {
  description = "ARN of the CV bucket"
  type        = string
}

variable "jobs_table_name" {
  description = "Jobs table name (job state source of truth)"
  type        = string
}

variable "jobs_table_arn" {
  description = "Jobs table ARN"
  type        = string
}

variable "vectorstore_cluster_arn" {
  description = "Aurora cluster ARN (Data API)"
  type        = string
}

variable "vectorstore_secret_arn" {
  description = "RDS-managed master secret ARN (Data API)"
  type        = string
}

variable "vectorstore_database" {
  description = "Vector store database name"
  type        = string
}

variable "python_layer_arn" {
  description = "ARN of the shared python dependencies layer"
  type        = string
}

variable "backend_src_dir" {
  description = "Path to the backend/ source folder"
  type        = string
}

variable "build_dir" {
  description = "Directory for the generated lambda zips"
  type        = string
}

variable "bedrock_model_id" {
  description = "Bedrock model id (EU inference profile) for the SLM steps"
  type        = string
}

variable "embed_model_id" {
  description = "Bedrock embedding model id (multilingual, same as JDs)"
  type        = string
}

variable "parsing_version" {
  description = "Parsing version stamped on chunks (targeted re-indexing)"
  type        = string
  default     = "1"
}

variable "external_tool_enabled" {
  description = "Feature flag: expose the external validate_employer tool to the agent (v0.5)"
  type        = bool
  default     = false
}

variable "hourly_cost_alarm_eur" {
  description = "Hourly Bedrock spend threshold for the cost alarm (EUR)"
  type        = number
  default     = 1
}
