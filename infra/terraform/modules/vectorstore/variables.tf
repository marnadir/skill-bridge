variable "name_prefix" {
  description = "Resource name prefix (project-environment)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR of the dedicated minimal VPC"
  type        = string
  default     = "10.20.0.0/24"
}

variable "availability_zones" {
  description = "Two AZs for the DB subnet group"
  type        = list(string)
}

variable "engine_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
}

variable "database_name" {
  description = "Initial database name"
  type        = string
  default     = "skillbridge"
}

variable "min_capacity" {
  description = "Serverless v2 min ACU (0 = scale to zero)"
  type        = number
  default     = 0
}

variable "max_capacity" {
  description = "Serverless v2 max ACU"
  type        = number
  default     = 2
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy (dev only)"
  type        = bool
  default     = false
}
