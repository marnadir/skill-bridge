##authentication (ADR-014): Cognito User Pool + SPA app client.
##The web app logs users in via the Hosted UI (authorization code +
##PKCE); API Gateway validates the issued JWTs at the edge.

data "aws_caller_identity" "current" {}

##--- user pool: the user registry ------------------------------------

resource "aws_cognito_user_pool" "users" {
  name = "${var.name_prefix}-users"

  ##internal tool: accounts are created by the admin, nobody
  ##self-registers from the login page
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  ##v0 demo: no MFA; turn on before any real production use
  mfa_configuration = "OFF"

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

##--- app client: the SPA registration --------------------------------

##NO client secret: a SPA cannot keep one (all its code is visible in
##the browser). PKCE replaces it with a per-login secret
resource "aws_cognito_user_pool_client" "spa" {
  name         = "${var.name_prefix}-web"
  user_pool_id = aws_cognito_user_pool.users.id

  generate_secret = false

  ##authorization code + PKCE (the SPA flow); USER_PASSWORD_AUTH is
  ##enabled for scripted E2E only — declared trade-off, disable for
  ##real production
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  ##return addresses MUST be pre-registered: a free-form redirect
  ##would let a malicious login link hijack the session
  callback_urls = var.callback_urls
  logout_urls   = var.callback_urls

  supported_identity_providers = ["COGNITO"]

  access_token_validity  = 60 ##minutes
  id_token_validity      = 60
  refresh_token_validity = 30 ##days

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
}

##--- hosted UI domain: the AWS-hosted login page ----------------------

##the user's password is typed on this page, never in our code
resource "aws_cognito_user_pool_domain" "users" {
  domain       = "${var.name_prefix}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.users.id
}
