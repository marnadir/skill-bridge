##dev environment: pure composition — the resources live in
##infra/terraform/modules/*, here they are instantiated and
##customized for this environment.
##CONSTRAINT: the CI role (github-actions-ci-skill-bridge, managed by
##aws-account-bootstrap) can create IAM roles ONLY with the
##skillbridge-* prefix — naming outside the prefix = AccessDenied

data "aws_caller_identity" "current" {}

locals {
  project     = "skillbridge"
  environment = "dev"
  name_prefix = "${local.project}-${local.environment}"
  account_id  = data.aws_caller_identity.current.account_id

  ##origins allowed to call the API and PUT on the cv bucket:
  ##the CloudFront domain + the local vite dev server
  fe_origins = [
    "https://${module.frontend.domain_name}",
    "http://localhost:5173",
  ]

  backend_src_dir = "${path.root}/../../../../backend"
  build_dir       = "${path.root}/.terraform/tmp"
}

##--- shared python dependencies layer -------------------------------

##built by scripts/build_lambda_layer.sh BEFORE plan/apply (see the
##terraform workflow): pydantic has a compiled core, so it ships as a
##layer instead of vendoring it in every function zip
data "archive_file" "python_deps_layer" {
  type        = "zip"
  source_dir  = "${local.build_dir}/layer"
  output_path = "${local.build_dir}/python-deps-layer.zip"
}

resource "aws_lambda_layer_version" "python_deps" {
  layer_name          = "${local.name_prefix}-python-deps"
  filename            = data.archive_file.python_deps_layer.output_path
  source_code_hash    = data.archive_file.python_deps_layer.output_base64sha256
  compatible_runtimes = ["python3.13"]
}

##--- modules ---------------------------------------------------------

module "frontend" {
  source = "../../modules/frontend-hosting"

  name_prefix = local.name_prefix
  bucket_name = "${local.name_prefix}-fe-${local.account_id}"
}

module "cv_bucket" {
  source = "../../modules/cv-bucket"

  bucket_name     = "${local.name_prefix}-cv-${local.account_id}"
  allowed_origins = local.fe_origins
}

module "vectorstore" {
  source = "../../modules/vectorstore"

  name_prefix         = local.name_prefix
  availability_zones  = ["eu-central-1a", "eu-central-1b"]
  engine_version      = "17.9"
  min_capacity        = 0 ##dev: scale to zero at rest
  max_capacity        = 2
  skip_final_snapshot = true ##dev environment
}

module "auth" {
  source = "../../modules/auth"

  name_prefix = local.name_prefix
  ##pre-registered post-login return addresses: the real app + local dev
  callback_urls = [
    "https://${module.frontend.domain_name}",
    "http://localhost:5173",
  ]
}

module "backend_api" {
  source = "../../modules/backend-api"

  name_prefix      = local.name_prefix
  jwt_issuer       = module.auth.issuer_url
  jwt_audience     = module.auth.client_id
  cv_bucket_arn    = module.cv_bucket.bucket_arn
  cv_bucket_name   = module.cv_bucket.bucket_id
  allowed_origins  = local.fe_origins
  python_layer_arn = aws_lambda_layer_version.python_deps.arn
  backend_src_dir  = local.backend_src_dir
  build_dir        = local.build_dir
}

module "cv_processing" {
  source = "../../modules/cv-processing"

  name_prefix             = local.name_prefix
  cv_bucket_id            = module.cv_bucket.bucket_id
  cv_bucket_arn           = module.cv_bucket.bucket_arn
  jobs_table_name         = module.backend_api.jobs_table_name
  jobs_table_arn          = module.backend_api.jobs_table_arn
  vectorstore_cluster_arn = module.vectorstore.cluster_arn
  vectorstore_secret_arn  = module.vectorstore.secret_arn
  vectorstore_database    = module.vectorstore.database_name
  python_layer_arn        = aws_lambda_layer_version.python_deps.arn
  backend_src_dir         = local.backend_src_dir
  build_dir               = local.build_dir

  ##cross-region EU inference profile (verified active on the account)
  bedrock_model_id = "eu.anthropic.claude-haiku-4-5-20251001-v1:0"
  ##external tool v0.5: enabled in dev
  external_tool_enabled = true
  ##multilingual embeddings: same model for CV and pre-indexed JDs
  embed_model_id  = "cohere.embed-multilingual-v3"
  parsing_version = "1"
}
