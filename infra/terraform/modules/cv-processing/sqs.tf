
resource "aws_sqs_queue" "cv_events" {
  name = "${var.name_prefix}-cv-events"
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
        ArnEquals = { "aws:SourceArn" = var.cv_bucket_arn }
      }
    }]
  })
}
