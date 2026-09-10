
data "archive_file" "step" {
  for_each = local.step_lambdas

  type        = "zip"
  source_dir  = "${var.backend_src_dir}/${each.key}"
  output_path = "${var.build_dir}/${each.key}.zip"
  excludes    = ["__pycache__"]
}


resource "aws_lambda_function" "step" {
  for_each = local.step_lambdas

  function_name = "${var.name_prefix}-${each.key}"
  role          = aws_iam_role.step[each.key].arn

  filename         = data.archive_file.step[each.key].output_path
  source_code_hash = data.archive_file.step[each.key].output_base64sha256

  runtime     = "python3.13"
  handler     = "lambda_function.lambda_handler"
  timeout     = each.value.timeout
  memory_size = each.value.memory_size
  layers      = [var.python_layer_arn]

  environment {
    variables = each.value.env
  }
}


data "archive_file" "start_cv_processing" {
  type        = "zip"
  source_dir  = "${var.backend_src_dir}/start-cv-processing"
  output_path = "${var.build_dir}/start-cv-processing.zip"
  excludes    = ["__pycache__"]
}


resource "aws_lambda_function" "start_cv_processing" {
  function_name = "${var.name_prefix}-start-cv-processing"
  role          = aws_iam_role.start_cv_processing.arn

  filename         = data.archive_file.start_cv_processing.output_path
  source_code_hash = data.archive_file.start_cv_processing.output_base64sha256

  runtime = "python3.13"
  handler = "lambda_function.lambda_handler"
  timeout = 10

  environment {
    variables = {
      STATE_MACHINE_ARN = aws_sfn_state_machine.cv_processing.arn
      JOBS_TABLE        = var.jobs_table_name
    }
  }
}


resource "aws_lambda_event_source_mapping" "start_cv_processing" {
  event_source_arn = aws_sqs_queue.cv_events.arn
  function_name    = aws_lambda_function.start_cv_processing.arn
  batch_size       = 10

  ##only failed messages return to the queue
  function_response_types = ["ReportBatchItemFailures"]
}

##--- external tool executor (doc 5.2-bis: two lambdas, two roles) ---

data "archive_file" "tool_validate_employer" {
  type        = "zip"
  source_dir  = "${var.backend_src_dir}/tool-validate-employer"
  output_path = "${var.build_dir}/tool-validate-employer.zip"
  excludes    = ["__pycache__"]
}

resource "aws_lambda_function" "tool_validate_employer" {
  function_name = "${var.name_prefix}-tool-validate-employer"
  role          = aws_iam_role.tool_validate_employer.arn

  filename         = data.archive_file.tool_validate_employer.output_path
  source_code_hash = data.archive_file.tool_validate_employer.output_base64sha256

  runtime = "python3.13"
  handler = "lambda_function.lambda_handler"
  ##own short timeout (doc 5.2-bis)
  timeout = 10

}
