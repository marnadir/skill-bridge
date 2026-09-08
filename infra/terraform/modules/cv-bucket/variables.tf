variable "bucket_name" {
  description = "Name of the private CV bucket"
  type        = string
}

variable "allowed_origins" {
  description = "Frontend origins allowed to PUT via presigned URL"
  type        = list(string)
}
