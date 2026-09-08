variable "name_prefix" {
  description = "Resource name prefix (project-environment)"
  type        = string
}

variable "cv_bucket_arn" {
  description = "ARN of the CV bucket (presigned PUT permission)"
  type        = string
}

variable "cv_bucket_name" {
  description = "Name of the CV bucket"
  type        = string
}

variable "allowed_origins" {
  description = "Frontend origins allowed by the API CORS"
  type        = list(string)
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
