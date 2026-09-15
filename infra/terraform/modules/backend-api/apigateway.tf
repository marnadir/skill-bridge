
##--- API Gateway (HTTP API) -----------------------------------------

##NOTE: the design (2.2) draws REST + IAM/key auth; v0 uses HTTP API
##without auth (internal webapp behind CORS). To be revisited (ADR-002)
resource "aws_apigatewayv2_api" "backend" {
  name          = "${var.name_prefix}-backend"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.allowed_origins
    allow_methods = ["GET", "POST"]
    allow_headers = ["content-type", "authorization"]
    max_age       = 3600
  }
}

##JWT authorizer (ADR-014): tokens are validated AT THE GATEWAY —
##signature (via the pool's public keys), expiry and audience. An
##unauthenticated request is rejected with 401 before the lambda
##is ever invoked (zero cost)
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.backend.id
  name             = "cognito-jwt"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    issuer   = var.jwt_issuer
    audience = [var.jwt_audience]
  }
}


resource "aws_apigatewayv2_integration" "backend_api" {
  api_id                 = aws_apigatewayv2_api.backend.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.backend_api.invoke_arn
  payload_format_version = "2.0"
}


resource "aws_apigatewayv2_route" "create_job" {
  api_id             = aws_apigatewayv2_api.backend.id
  route_key          = "POST /jobs"
  target             = "integrations/${aws_apigatewayv2_integration.backend_api.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}


resource "aws_apigatewayv2_route" "get_job" {
  api_id             = aws_apigatewayv2_api.backend.id
  route_key          = "GET /jobs/{jobId}"
  target             = "integrations/${aws_apigatewayv2_integration.backend_api.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}


resource "aws_apigatewayv2_stage" "backend" {
  api_id      = aws_apigatewayv2_api.backend.id
  name        = "$default"
  auto_deploy = true
}
