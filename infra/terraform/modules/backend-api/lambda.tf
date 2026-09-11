
data "archive_file" "backend_api" {
  type        = "zip"
  source_dir  = "${var.backend_src_dir}/backend-api"
  output_path = "${var.build_dir}/backend-api.zip"
  excludes    = ["__pycache__", "local_server.py"]
}


resource "aws_lambda_function" "backend_api" {
  function_name = "${var.name_prefix}-backend-api"
  role          = aws_iam_role.backend_api.arn

  filename         = data.archive_file.backend_api.output_path
  source_code_hash = data.archive_file.backend_api.output_base64sha256

  runtime = "python3.13"
  handler = "lambda_function.lambda_handler"
  timeout = 10
  layers  = [var.python_layer_arn]

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      BUCKET_NAME = var.cv_bucket_name
      JOBS_TABLE  = aws_dynamodb_table.jobs.name
    }
  }
}


resource "aws_lambda_permission" "backend_api" {
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backend_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.backend.execution_arn}/*/*"
}
