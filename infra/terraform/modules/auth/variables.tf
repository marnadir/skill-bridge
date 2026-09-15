variable "name_prefix" {
  description = "Resource name prefix (project-environment)"
  type        = string
}

variable "callback_urls" {
  description = "Pre-registered post-login/logout return URLs (CloudFront + local dev)"
  type        = list(string)
}
