##CV processing pipeline (doc sez. 4): S3 upload event -> SQS ->
##starter lambda -> state machine with the ingestion steps:
##[Parsing] -> [PII redaction] -> [Guardrail] -> [Normalize] ->
##[Chunk] -> [Embed]

data "aws_caller_identity" "current" {}

##--- SQS queue + DLQ ------------------------------------------------

resource "aws_sqs_queue" "cv_events_dlq" {
  name                      = "${var.name_prefix}-cv-events-dlq"
  message_retention_seconds = 1209600 ##14 days to inspect failures
}
