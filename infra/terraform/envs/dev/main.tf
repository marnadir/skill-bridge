##prefisso comune ai nomi delle risorse (skillbridge-dev-*).
##VINCOLO: il ruolo CI (github-actions-ci-skill-bridge, gestito da
##aws-account-bootstrap) puo' creare ruoli IAM SOLO col prefisso
##skillbridge-* — nominare fuori prefisso = AccessDenied in pipeline
locals {
  project     = "skillbridge"
  environment = "dev"
  name_prefix = "${local.project}-${local.environment}"
}

##le risorse del progetto si aggiungono qui (o in file dedicati per area)
