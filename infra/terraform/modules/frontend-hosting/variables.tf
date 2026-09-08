variable "name_prefix" {
  description = "Resource name prefix (project-environment)"
  type        = string
}

variable "bucket_name" {
  description = "Name of the frontend build bucket"
  type        = string
}

variable "price_class" {
  description = "CloudFront price class"
  type        = string
  default     = "PriceClass_100" ##EU/North America edges only
}
