
resource "aws_sfn_state_machine" "cv_processing" {
  name     = "${var.name_prefix}-cv-processing"
  role_arn = aws_iam_role.cv_processing_sfn.arn

  definition = jsonencode({
    Comment = "CV processing pipeline - ingestion steps (doc sez. 4)"
    StartAt = "Parsing"
    States = {
      Parsing = {
        Type           = "Task"
        Resource       = aws_lambda_function.step["parse-cv"].arn
        ResultPath     = "$.parsing"
        TimeoutSeconds = 180
        Retry          = local.step_retry
        ##failed sanity check = review queue, NOT an error (doc 4.1)
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
          TableName                = var.jobs_table_name
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
      ##legitimate outcome, not a failure: a human will look at the file
      SetJobNeedsReview = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName                = var.jobs_table_name
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
          TableName                = var.jobs_table_name
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
