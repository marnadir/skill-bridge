##CV processing pipeline: S3 upload event -> SQS -> lambda consumer
##-> Step Function execution (one per uploaded CV)

##--- SQS queue + DLQ ------------------------------------------------

resource "aws_sqs_queue" "cv_events_dlq" {
  name                      = "${local.name_prefix}-cv-events-dlq"
  message_retention_seconds = 1209600 ##14 days to inspect failures
}

resource "aws_sqs_queue" "cv_events" {
  name = "${local.name_prefix}-cv-events"
  ##must be >= 6x the consumer lambda timeout (aws recommendation)
  visibility_timeout_seconds = 60

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.cv_events_dlq.arn
    maxReceiveCount     = 3
  })
}

##only the cv bucket can publish upload events to the queue
resource "aws_sqs_queue_policy" "cv_events" {
  queue_url = aws_sqs_queue.cv_events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowS3Notifications"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.cv_events.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_s3_bucket.cv.arn }
      }
    }]
  })
}

##--- S3 -> SQS notification -----------------------------------------

resource "aws_s3_bucket_notification" "cv" {
  bucket = aws_s3_bucket.cv.id

  queue {
    queue_arn     = aws_sqs_queue.cv_events.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "cv/"
  }

  ##the queue policy must exist before s3 validates the destination
  depends_on = [aws_sqs_queue_policy.cv_events]
}

##--- Step Function (skeleton) ---------------------------------------

##CONSTRAINT: role names must start with skillbridge-* (see main.tf)
resource "aws_iam_role" "cv_processing_sfn" {
  name = "${local.name_prefix}-cv-processing-sfn"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

##placeholder workflow: the real processing states (parse, analyze,
##store) will be added by the next features
resource "aws_sfn_state_machine" "cv_processing" {
  name     = "${local.name_prefix}-cv-processing"
  role_arn = aws_iam_role.cv_processing_sfn.arn

  definition = jsonencode({
    Comment = "CV processing pipeline (skeleton)"
    StartAt = "Todo"
    States = {
      Todo = {
        Type = "Pass"
        Result = {
          status = "not-implemented-yet"
        }
        ResultPath = "$.processing"
        End        = true
      }
    }
  })
}

##--- consumer lambda ------------------------------------------------

resource "aws_iam_role" "start_cv_processing" {
  name = "${local.name_prefix}-start-cv-processing-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "start_cv_processing" {
  name = "start-cv-processing"
  role = aws_iam_role.start_cv_processing.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ConsumeQueue"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.cv_events.arn
      },
      {
        Sid      = "StartStateMachine"
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = aws_sfn_state_machine.cv_processing.arn
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

data "archive_file" "start_cv_processing" {
  type        = "zip"
  source_dir  = "${path.module}/../../../../backend/start-cv-processing"
  output_path = "${path.module}/.terraform/tmp/start-cv-processing.zip"
  excludes    = ["__pycache__"]
}

resource "aws_lambda_function" "start_cv_processing" {
  function_name = "${local.name_prefix}-start-cv-processing"
  role          = aws_iam_role.start_cv_processing.arn

  filename         = data.archive_file.start_cv_processing.output_path
  source_code_hash = data.archive_file.start_cv_processing.output_base64sha256

  runtime = "python3.13"
  handler = "lambda_function.lambda_handler"
  timeout = 10

  environment {
    variables = {
      STATE_MACHINE_ARN = aws_sfn_state_machine.cv_processing.arn
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

output "cv_processing_state_machine_arn" {
  value = aws_sfn_state_machine.cv_processing.arn
}
