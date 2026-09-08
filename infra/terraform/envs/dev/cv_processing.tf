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

##the state machine can only invoke the extract lambda and write to
##the analysis table
resource "aws_iam_role_policy" "cv_processing_sfn" {
  name = "cv-processing"
  role = aws_iam_role.cv_processing_sfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeExtractSkills"
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.extract_skills.arn
      },
      {
        Sid      = "StoreAnalysis"
        Effect   = "Allow"
        Action   = "dynamodb:PutItem"
        Resource = aws_dynamodb_table.cv_analysis.arn
      },
      {
        ##ogni stato aggiorna lo stato del job (doc 2.2)
        Sid      = "UpdateJobStatus"
        Effect   = "Allow"
        Action   = "dynamodb:UpdateItem"
        Resource = aws_dynamodb_table.jobs.arn
      },
    ]
  })
}

##ExtractSkills (lambda + bedrock) -> StoreAnalysis (dynamodb putItem)
resource "aws_sfn_state_machine" "cv_processing" {
  name     = "${local.name_prefix}-cv-processing"
  role_arn = aws_iam_role.cv_processing_sfn.arn

  definition = jsonencode({
    Comment = "CV processing pipeline"
    StartAt = "ExtractSkills"
    States = {
      ExtractSkills = {
        Type           = "Task"
        Resource       = aws_lambda_function.extract_skills.arn
        ResultPath     = "$.extraction"
        TimeoutSeconds = 180
        Retry = [
          {
            ErrorEquals = [
              "Lambda.ServiceException",
              "Lambda.TooManyRequestsException",
              "ThrottlingException",
            ]
            IntervalSeconds = 5
            MaxAttempts     = 3
            BackoffRate     = 2
          },
        ]
        ##il CV non si perde mai in silenzio (doc 3.3): ogni errore
        ##finisce sullo stato del job
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            ResultPath  = "$.error_info"
            Next        = "SetJobFailed"
          },
        ]
        Next = "StoreAnalysis"
      }
      StoreAnalysis = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:putItem"
        Parameters = {
          TableName = aws_dynamodb_table.cv_analysis.name
          Item = {
            cv_key       = { "S.$" = "$.key" }
            job_id       = { "S.$" = "$.job_id" }
            bucket       = { "S.$" = "$.bucket" }
            model        = { "S.$" = "$.extraction.model" }
            analysis     = { "S.$" = "States.JsonToString($.extraction.analysis)" }
            markdown_key = { "S.$" = "$.extraction.markdown_key" }
            analyzed_at  = { "S.$" = "$$.State.EnteredTime" }
          }
        }
        ResultPath = null
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            ResultPath  = "$.error_info"
            Next        = "SetJobFailed"
          },
        ]
        Next = "SetJobCompleted"
      }
      SetJobCompleted = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName                = aws_dynamodb_table.jobs.name
          Key                      = { job_id = { "S.$" = "$.job_id" } }
          UpdateExpression         = "SET #s = :completed, updated_at = :now"
          ExpressionAttributeNames = { "#s" = "status" }
          ExpressionAttributeValues = {
            ":completed" = { S = "COMPLETED" }
            ":now"       = { "S.$" = "$$.State.EnteredTime" }
          }
        }
        End = true
      }
      SetJobFailed = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName                = aws_dynamodb_table.jobs.name
          Key                      = { job_id = { "S.$" = "$.job_id" } }
          UpdateExpression         = "SET #s = :failed, #e = :error, updated_at = :now"
          ExpressionAttributeNames = { "#s" = "status", "#e" = "error" }
          ExpressionAttributeValues = {
            ":failed" = { S = "FAILED" }
            ":error"  = { "S.$" = "States.JsonToString($.error_info)" }
            ":now"    = { "S.$" = "$$.State.EnteredTime" }
          }
        }
        Next = "Failed"
      }
      Failed = {
        Type  = "Fail"
        Error = "CvProcessingFailed"
        Cause = "See the job error attribute on the jobs table"
      }
    }
  })
}

##--- analysis results table -----------------------------------------

resource "aws_dynamodb_table" "cv_analysis" {
  name         = "${local.name_prefix}-cv-analysis"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "cv_key"

  attribute {
    name = "cv_key"
    type = "S"
  }
}

##--- extract-skills lambda ------------------------------------------

##cross-region EU inference profile (verified active on the account)
locals {
  bedrock_model_id = "eu.anthropic.claude-haiku-4-5-20251001-v1:0"
}

resource "aws_iam_role" "extract_skills" {
  name = "${local.name_prefix}-extract-skills-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "extract_skills" {
  name = "extract-skills"
  role = aws_iam_role.extract_skills.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadCv"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.cv.arn}/cv/*"
      },
      {
        ##markdown/ is outside the cv/ notification prefix: no loop
        Sid      = "WriteMarkdown"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cv.arn}/markdown/*"
      },
      {
        Sid    = "InvokeModel"
        Effect = "Allow"
        Action = "bedrock:InvokeModel"
        ##the EU inference profile routes to eu-* foundation models
        Resource = [
          "arn:aws:bedrock:eu-central-1:${data.aws_caller_identity.current.account_id}:inference-profile/${local.bedrock_model_id}",
          "arn:aws:bedrock:eu-*::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
        ]
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

data "archive_file" "extract_skills" {
  type        = "zip"
  source_dir  = "${path.module}/../../../../backend/extract-skills"
  output_path = "${path.module}/.terraform/tmp/extract-skills.zip"
  excludes    = ["__pycache__"]
}

resource "aws_lambda_function" "extract_skills" {
  function_name = "${local.name_prefix}-extract-skills"
  role          = aws_iam_role.extract_skills.arn

  filename         = data.archive_file.extract_skills.output_path
  source_code_hash = data.archive_file.extract_skills.output_base64sha256

  runtime = "python3.13"
  handler = "lambda_function.lambda_handler"
  ##bedrock call with an attached document can take tens of seconds
  timeout     = 120
  memory_size = 512

  environment {
    variables = {
      MODEL_ID = local.bedrock_model_id
      ##the markdown transcription of a multi-page CV can be long
      MAX_TOKENS  = "8000"
      TEMPERATURE = "0"
    }
  }
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
        ##idempotenza: transizione condizionale PENDING_UPLOAD -> PROCESSING
        Sid      = "ClaimJob"
        Effect   = "Allow"
        Action   = "dynamodb:UpdateItem"
        Resource = aws_dynamodb_table.jobs.arn
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
      JOBS_TABLE        = aws_dynamodb_table.jobs.name
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
