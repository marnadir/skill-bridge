##backend API (doc 3.1): API Gateway HTTP API + lambda backend-api.
##POST /jobs crea il job su DynamoDB e restituisce la presigned URL;
##GET /jobs/{jobId} e' il polling dello stato dalla web app

##--- jobs table: fonte di verita' dello stato dei job ---------------

resource "aws_dynamodb_table" "jobs" {
  name         = "${local.name_prefix}-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }
}

##--- backend-api lambda ---------------------------------------------

resource "aws_iam_role" "backend_api" {
  name = "${local.name_prefix}-backend-api-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "backend_api" {
  name = "backend-api"
  role = aws_iam_role.backend_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Jobs"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
        ]
        Resource = aws_dynamodb_table.jobs.arn
      },
      {
        ##needed to sign presigned PUT URLs for the cv/ prefix
        Sid      = "PresignUpload"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cv.arn}/cv/*"
      },
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*"
      },
    ]
  })
}

data "archive_file" "backend_api" {
  type        = "zip"
  source_dir  = "${path.module}/../../../../backend/backend-api"
  output_path = "${path.module}/.terraform/tmp/backend-api.zip"
  excludes    = ["__pycache__", "local_server.py"]
}

resource "aws_lambda_function" "backend_api" {
  function_name = "${local.name_prefix}-backend-api"
  role          = aws_iam_role.backend_api.arn

  filename         = data.archive_file.backend_api.output_path
  source_code_hash = data.archive_file.backend_api.output_base64sha256

  runtime = "python3.13"
  handler = "lambda_function.lambda_handler"
  timeout = 10

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.cv.bucket
      JOBS_TABLE  = aws_dynamodb_table.jobs.name
    }
  }
}

##--- API Gateway (HTTP API) -----------------------------------------

##NOTA: il design (2.2) disegna REST + auth IAM/key; per la v0 usiamo
##HTTP API senza auth (webapp interna dietro CORS). Da rivalutare.
resource "aws_apigatewayv2_api" "backend" {
  name          = "${local.name_prefix}-backend"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = local.fe_origins
    allow_methods = ["GET", "POST"]
    allow_headers = ["content-type"]
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_integration" "backend_api" {
  api_id                 = aws_apigatewayv2_api.backend.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.backend_api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "create_job" {
  api_id    = aws_apigatewayv2_api.backend.id
  route_key = "POST /jobs"
  target    = "integrations/${aws_apigatewayv2_integration.backend_api.id}"
}

resource "aws_apigatewayv2_route" "get_job" {
  api_id    = aws_apigatewayv2_api.backend.id
  route_key = "GET /jobs/{jobId}"
  target    = "integrations/${aws_apigatewayv2_integration.backend_api.id}"
}

resource "aws_apigatewayv2_stage" "backend" {
  api_id      = aws_apigatewayv2_api.backend.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "backend_api" {
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backend_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.backend.execution_arn}/*/*"
}

##da usare come VITE_API_BASE_URL nel frontend
output "api_base_url" {
  value = aws_apigatewayv2_api.backend.api_endpoint
}
