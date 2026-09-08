
##--- S3 -> SQS notification -----------------------------------------

resource "aws_s3_bucket_notification" "cv" {
  bucket = var.cv_bucket_id

  queue {
    queue_arn     = aws_sqs_queue.cv_events.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "cv/"
  }

  ##the queue policy must exist before s3 validates the destination
  depends_on = [aws_sqs_queue_policy.cv_events]
}
