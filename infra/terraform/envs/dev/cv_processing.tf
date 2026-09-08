##CV processing pipeline (doc sez. 4): S3 upload event -> SQS ->
##starter lambda -> state machine con gli step di ingestion:
##[Parsing] -> [PII redaction] -> [Guardrail] (step 4-6 nella
##prossima tranche)

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

##--- mappa PII (token -> identita', separata dai dati di pipeline) ---

resource "aws_dynamodb_table" "pii_map" {
  name         = "${local.name_prefix}-pii-map"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }
}

##--- le lambda degli step di ingestion ------------------------------

locals {
  ##cross-region EU inference profile (verified active on the account)
  bedrock_model_id = "eu.anthropic.claude-haiku-4-5-20251001-v1:0"
  ##multilingual embeddings: same model for CV and pre-indexed JDs
  ##(comparable spaces, doc 4.6); batch up to 96 texts per call
  embed_model_id = "cohere.embed-multilingual-v3"

  bedrock_statement = {
    Sid    = "InvokeModel"
    Effect = "Allow"
    Action = "bedrock:InvokeModel"
    ##the EU inference profile routes to eu-* foundation models
    Resource = [
      "arn:aws:bedrock:eu-central-1:${data.aws_caller_identity.current.account_id}:inference-profile/${local.bedrock_model_id}",
      "arn:aws:bedrock:eu-*::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
    ]
  }

  embed_statement = {
    Sid      = "InvokeEmbedModel"
    Effect   = "Allow"
    Action   = "bedrock:InvokeModel"
    Resource = "arn:aws:bedrock:eu-central-1::foundation-model/${local.embed_model_id}"
  }

  logs_statement = {
    Sid    = "Logs"
    Effect = "Allow"
    Action = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*"
  }

  ##una lambda per step: ognuna legge SOLO il prefisso prodotto dallo
  ##step precedente e scrive SOLO il proprio (least privilege)
  step_lambdas = {
    "parse-cv" = {
      timeout     = 120
      memory_size = 512
      env         = { MODEL_ID = local.bedrock_model_id, MAX_TOKENS = "8000" }
      statements = [
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
      ]
    }
    "redact-pii" = {
      timeout     = 60
      memory_size = 256
      env         = { MODEL_ID = local.bedrock_model_id, PII_MAP_TABLE = aws_dynamodb_table.pii_map.name }
      statements = [
        {
          Sid      = "ReadMarkdown"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${aws_s3_bucket.cv.arn}/markdown/*"
        },
        {
          Sid      = "WriteRedacted"
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "${aws_s3_bucket.cv.arn}/redacted/*"
        },
        {
          Sid      = "StorePiiMap"
          Effect   = "Allow"
          Action   = "dynamodb:PutItem"
          Resource = aws_dynamodb_table.pii_map.arn
        },
      ]
    }
    "guardrail" = {
      timeout     = 60
      memory_size = 256
      env         = { MODEL_ID = local.bedrock_model_id }
      statements = [
        {
          Sid      = "ReadRedacted"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${aws_s3_bucket.cv.arn}/redacted/*"
        },
        {
          Sid      = "WriteGuarded"
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "${aws_s3_bucket.cv.arn}/guarded/*"
        },
      ]
    }
    "normalize-skills" = {
      timeout     = 120
      memory_size = 256
      env = {
        MODEL_ID       = local.bedrock_model_id
        EMBED_MODEL_ID = local.embed_model_id
      }
      statements = [
        {
          Sid      = "ReadGuarded"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${aws_s3_bucket.cv.arn}/guarded/*"
        },
        {
          Sid      = "WriteNormalized"
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "${aws_s3_bucket.cv.arn}/normalized/*"
        },
        local.embed_statement,
      ]
    }
    "chunk-cv" = {
      timeout     = 120
      memory_size = 256
      env = {
        MODEL_ID        = local.bedrock_model_id
        PARSING_VERSION = "1"
      }
      statements = [
        {
          Sid      = "ReadNormalized"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${aws_s3_bucket.cv.arn}/normalized/*"
        },
        {
          Sid      = "WriteChunks"
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "${aws_s3_bucket.cv.arn}/chunks/*"
        },
      ]
    }
    "embed-cv" = {
      ##il cluster a riposo riparte in ~15s: timeout largo
      timeout     = 180
      memory_size = 512
      env = {
        EMBED_MODEL_ID = local.embed_model_id
        CLUSTER_ARN    = aws_rds_cluster.vectorstore.arn
        SECRET_ARN     = aws_rds_cluster.vectorstore.master_user_secret[0].secret_arn
        DATABASE       = aws_rds_cluster.vectorstore.database_name
      }
      statements = [
        {
          Sid      = "ReadChunks"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${aws_s3_bucket.cv.arn}/chunks/*"
        },
        {
          Sid    = "DataApi"
          Effect = "Allow"
          Action = [
            "rds-data:ExecuteStatement",
            "rds-data:BeginTransaction",
            "rds-data:CommitTransaction",
            "rds-data:RollbackTransaction",
          ]
          Resource = aws_rds_cluster.vectorstore.arn
        },
        {
          ##la Data API si autentica col secret master gestito da RDS
          Sid      = "ReadDbSecret"
          Effect   = "Allow"
          Action   = "secretsmanager:GetSecretValue"
          Resource = aws_rds_cluster.vectorstore.master_user_secret[0].secret_arn
        },
        local.embed_statement,
      ]
    }
  }
}

resource "aws_iam_role" "step" {
  for_each = local.step_lambdas

  ##CONSTRAINT: role names must start with skillbridge-* (see main.tf)
  name = "${local.name_prefix}-${each.key}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "step" {
  for_each = local.step_lambdas

  name = each.key
  role = aws_iam_role.step[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      each.value.statements,
      [local.bedrock_statement, local.logs_statement],
    )
  })
}

data "archive_file" "step" {
  for_each = local.step_lambdas

  type        = "zip"
  source_dir  = "${path.module}/../../../../backend/${each.key}"
  output_path = "${path.module}/.terraform/tmp/${each.key}.zip"
  excludes    = ["__pycache__"]
}

resource "aws_lambda_function" "step" {
  for_each = local.step_lambdas

  function_name = "${local.name_prefix}-${each.key}"
  role          = aws_iam_role.step[each.key].arn

  filename         = data.archive_file.step[each.key].output_path
  source_code_hash = data.archive_file.step[each.key].output_base64sha256

  runtime     = "python3.13"
  handler     = "lambda_function.lambda_handler"
  timeout     = each.value.timeout
  memory_size = each.value.memory_size
  layers      = [aws_lambda_layer_version.python_deps.arn]

  environment {
    variables = each.value.env
  }
}

##--- state machine ---------------------------------------------------

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

##la state machine puo' solo invocare le lambda degli step e
##aggiornare lo stato del job
resource "aws_iam_role_policy" "cv_processing_sfn" {
  name = "cv-processing"
  role = aws_iam_role.cv_processing_sfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeStepLambdas"
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = [for l in aws_lambda_function.step : l.arn]
      },
      {
        ##ogni esito aggiorna lo stato del job (doc 2.2)
        Sid      = "UpdateJobStatus"
        Effect   = "Allow"
        Action   = "dynamodb:UpdateItem"
        Resource = aws_dynamodb_table.jobs.arn
      },
    ]
  })
}

locals {
  ##retry comune: errori transitori di lambda/bedrock
  step_retry = [
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

  ##catch comune: il CV non si perde mai in silenzio (doc 3.3)
  catch_to_failed = [
    {
      ErrorEquals = ["States.ALL"]
      ResultPath  = "$.error_info"
      Next        = "SetJobFailed"
    },
  ]
}

resource "aws_sfn_state_machine" "cv_processing" {
  name     = "${local.name_prefix}-cv-processing"
  role_arn = aws_iam_role.cv_processing_sfn.arn

  definition = jsonencode({
    Comment = "CV processing pipeline - ingestion steps 1-3 (doc sez. 4)"
    StartAt = "Parsing"
    States = {
      Parsing = {
        Type           = "Task"
        Resource       = aws_lambda_function.step["parse-cv"].arn
        ResultPath     = "$.parsing"
        TimeoutSeconds = 180
        Retry          = local.step_retry
        ##sanity check fallito = coda di revisione, NON errore (doc 4.1)
        Catch = concat(
          [
            {
              ErrorEquals = ["SanityCheckFailed"]
              ResultPath  = "$.review_info"
              Next        = "SetJobNeedsReview"
            },
          ],
          local.catch_to_failed,
        )
        Next = "PiiRedaction"
      }
      PiiRedaction = {
        Type     = "Task"
        Resource = aws_lambda_function.step["redact-pii"].arn
        Parameters = {
          "job_id.$"       = "$.job_id"
          "bucket.$"       = "$.bucket"
          "markdown_key.$" = "$.parsing.markdown_key"
        }
        ResultPath     = "$.redaction"
        TimeoutSeconds = 120
        Retry          = local.step_retry
        Catch          = local.catch_to_failed
        Next           = "Guardrail"
      }
      Guardrail = {
        Type     = "Task"
        Resource = aws_lambda_function.step["guardrail"].arn
        Parameters = {
          "job_id.$"       = "$.job_id"
          "bucket.$"       = "$.bucket"
          "redacted_key.$" = "$.redaction.redacted_key"
        }
        ResultPath     = "$.guardrail"
        TimeoutSeconds = 120
        Retry          = local.step_retry
        Catch          = local.catch_to_failed
        Next           = "NormalizeSkills"
      }
      NormalizeSkills = {
        Type     = "Task"
        Resource = aws_lambda_function.step["normalize-skills"].arn
        Parameters = {
          "job_id.$"      = "$.job_id"
          "bucket.$"      = "$.bucket"
          "guarded_key.$" = "$.guardrail.guarded_key"
        }
        ResultPath     = "$.normalization"
        TimeoutSeconds = 180
        Retry          = local.step_retry
        Catch          = local.catch_to_failed
        Next           = "ChunkCv"
      }
      ChunkCv = {
        Type     = "Task"
        Resource = aws_lambda_function.step["chunk-cv"].arn
        Parameters = {
          "job_id.$"         = "$.job_id"
          "bucket.$"         = "$.bucket"
          "normalized_key.$" = "$.normalization.normalized_key"
        }
        ResultPath     = "$.chunking"
        TimeoutSeconds = 180
        Retry          = local.step_retry
        Catch          = local.catch_to_failed
        Next           = "EmbedCv"
      }
      EmbedCv = {
        Type     = "Task"
        Resource = aws_lambda_function.step["embed-cv"].arn
        Parameters = {
          "job_id.$"     = "$.job_id"
          "bucket.$"     = "$.bucket"
          "chunks_key.$" = "$.chunking.chunks_key"
        }
        ResultPath     = "$.embedding"
        TimeoutSeconds = 240
        Retry          = local.step_retry
        Catch          = local.catch_to_failed
        Next           = "SetJobCompleted"
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
      ##esito legittimo, non fallimento: un umano guardera' il file
      SetJobNeedsReview = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName                = aws_dynamodb_table.jobs.name
          Key                      = { job_id = { "S.$" = "$.job_id" } }
          UpdateExpression         = "SET #s = :review, #e = :reason, updated_at = :now"
          ExpressionAttributeNames = { "#s" = "status", "#e" = "error" }
          ExpressionAttributeValues = {
            ":review" = { S = "NEEDS_REVIEW" }
            ":reason" = { "S.$" = "States.JsonToString($.review_info)" }
            ":now"    = { "S.$" = "$$.State.EnteredTime" }
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
      local.logs_statement,
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

##--- shared python dependencies layer -------------------------------

##built by scripts/build_lambda_layer.sh BEFORE plan/apply (see the
##terraform workflow): pydantic has a compiled core, so it ships as a
##layer instead of vendoring it in every function zip
data "archive_file" "python_deps_layer" {
  type        = "zip"
  source_dir  = "${path.module}/.terraform/tmp/layer"
  output_path = "${path.module}/.terraform/tmp/python-deps-layer.zip"
}

resource "aws_lambda_layer_version" "python_deps" {
  layer_name          = "${local.name_prefix}-python-deps"
  filename            = data.archive_file.python_deps_layer.output_path
  source_code_hash    = data.archive_file.python_deps_layer.output_base64sha256
  compatible_runtimes = ["python3.13"]
}
