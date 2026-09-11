
##--- the ingestion step lambdas -------------------------------------

locals {
  bedrock_statement = {
    Sid    = "InvokeModel"
    Effect = "Allow"
    ##strands calls ConverseStream: the streaming action is required too
    Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    ##the EU inference profile routes to eu-* foundation models
    Resource = [
      "arn:aws:bedrock:eu-central-1:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_id}",
      "arn:aws:bedrock:eu-*::foundation-model/${trimprefix(var.bedrock_model_id, "eu.")}",
    ]
  }

  embed_statement = {
    Sid      = "InvokeEmbedModel"
    Effect   = "Allow"
    Action   = "bedrock:InvokeModel"
    Resource = "arn:aws:bedrock:eu-central-1::foundation-model/${var.embed_model_id}"
  }

  xray_statement = {
    Sid    = "Xray"
    Effect = "Allow"
    Action = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
    ]
    Resource = "*"
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

  ##one lambda per step: each reads ONLY the prefix produced by the
  ##previous step and writes ONLY its own (least privilege)
  step_lambdas = {
    "parse-cv" = {
      timeout     = 120
      memory_size = 512
      env         = { MODEL_ID = var.bedrock_model_id, MAX_TOKENS = "8000" }
      statements = [
        {
          Sid      = "ReadCv"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${var.cv_bucket_arn}/cv/*"
        },
        {
          ##markdown/ is outside the cv/ notification prefix: no loop
          Sid      = "WriteMarkdown"
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "${var.cv_bucket_arn}/markdown/*"
        },
      ]
    }
    "redact-pii" = {
      timeout     = 60
      memory_size = 256
      env         = { MODEL_ID = var.bedrock_model_id, PII_MAP_TABLE = aws_dynamodb_table.pii_map.name }
      statements = [
        {
          Sid      = "ReadMarkdown"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${var.cv_bucket_arn}/markdown/*"
        },
        {
          Sid      = "WriteRedacted"
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "${var.cv_bucket_arn}/redacted/*"
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
      env         = { MODEL_ID = var.bedrock_model_id }
      statements = [
        {
          Sid      = "ReadRedacted"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${var.cv_bucket_arn}/redacted/*"
        },
        {
          Sid      = "WriteGuarded"
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "${var.cv_bucket_arn}/guarded/*"
        },
      ]
    }
    "normalize-skills" = {
      timeout     = 120
      memory_size = 256
      env = {
        MODEL_ID       = var.bedrock_model_id
        EMBED_MODEL_ID = var.embed_model_id
      }
      statements = [
        {
          Sid      = "ReadGuarded"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${var.cv_bucket_arn}/guarded/*"
        },
        {
          Sid      = "WriteNormalized"
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "${var.cv_bucket_arn}/normalized/*"
        },
        local.embed_statement,
      ]
    }
    "chunk-cv" = {
      timeout     = 120
      memory_size = 256
      env = {
        MODEL_ID        = var.bedrock_model_id
        PARSING_VERSION = var.parsing_version
      }
      statements = [
        {
          Sid      = "ReadNormalized"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${var.cv_bucket_arn}/normalized/*"
        },
        {
          Sid      = "WriteChunks"
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "${var.cv_bucket_arn}/chunks/*"
        },
      ]
    }
    "embed-cv" = {
      ##a paused cluster resumes in ~15s: generous timeout
      timeout     = 180
      memory_size = 512
      env = {
        EMBED_MODEL_ID = var.embed_model_id
        CLUSTER_ARN    = var.vectorstore_cluster_arn
        SECRET_ARN     = var.vectorstore_secret_arn
        DATABASE       = var.vectorstore_database
      }
      statements = [
        {
          Sid      = "ReadChunks"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${var.cv_bucket_arn}/chunks/*"
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
          Resource = var.vectorstore_cluster_arn
        },
        {
          ##the Data API authenticates with the RDS-managed secret
          Sid      = "ReadDbSecret"
          Effect   = "Allow"
          Action   = "secretsmanager:GetSecretValue"
          Resource = var.vectorstore_secret_arn
        },
        local.embed_statement,
      ]
    }
    "agent-matching" = {
      ##the agent loop runs a few model+tool rounds: generous timeout
      timeout     = 300
      memory_size = 512
      env = {
        MODEL_ID            = var.bedrock_model_id
        EMBED_MODEL_ID      = var.embed_model_id
        CLUSTER_ARN         = var.vectorstore_cluster_arn
        SECRET_ARN          = var.vectorstore_secret_arn
        DATABASE            = var.vectorstore_database
        MAX_TOOL_CALLS      = "8"
        TIME_BUDGET_SECONDS = "180"
        TOP_K               = "5"
        ##external tool v0.5 (doc 5.2-bis), behind feature flag
        EXTERNAL_TOOL_ENABLED = var.external_tool_enabled ? "true" : "false"
        EXECUTOR_FUNCTION     = aws_lambda_function.tool_validate_employer.function_name
        GOVERNANCE_TABLE      = aws_dynamodb_table.governance.name
        MAX_EXTERNAL_CALLS    = "3"
      }
      statements = [
        {
          Sid      = "ReadChunks"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${var.cv_bucket_arn}/chunks/*"
        },
        {
          ##internal tool search_jd: read-only kNN on jd_chunks
          Sid      = "DataApiQuery"
          Effect   = "Allow"
          Action   = "rds-data:ExecuteStatement"
          Resource = var.vectorstore_cluster_arn
        },
        {
          Sid      = "ReadDbSecret"
          Effect   = "Allow"
          Action   = "secretsmanager:GetSecretValue"
          Resource = var.vectorstore_secret_arn
        },
        {
          ##decision to the agent, execution outside: the agent can
          ##invoke ONLY the isolated executor (doc 5.2-bis)
          Sid      = "InvokeExternalToolExecutor"
          Effect   = "Allow"
          Action   = "lambda:InvokeFunction"
          Resource = aws_lambda_function.tool_validate_employer.arn
        },
        {
          ##shared circuit breaker state (doc 5.3)
          Sid      = "Breaker"
          Effect   = "Allow"
          Action   = ["dynamodb:GetItem", "dynamodb:PutItem"]
          Resource = aws_dynamodb_table.governance.arn
        },
        local.embed_statement,
      ]
    }
  }
}


locals {
  ##common retry: transient lambda/bedrock errors
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

  ##common catch: no CV is ever lost silently (doc 3.3)
  catch_to_failed = [
    {
      ErrorEquals = ["States.ALL"]
      ResultPath  = "$.error_info"
      Next        = "SetJobFailed"
    },
  ]
}
