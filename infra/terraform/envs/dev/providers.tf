provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      Project     = "skill-bridge"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
