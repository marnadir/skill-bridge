##state remoto nel bucket condiviso dell'account (gestito dal repo
##aws-account-bootstrap); key con prefisso progetto, come da convenzione
terraform {
  backend "s3" {
    bucket       = "tfstate-820329008292-side-project"
    key          = "skill-bridge/envs/dev/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
