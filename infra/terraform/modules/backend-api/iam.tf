
##--- backend-api lambda ---------------------------------------------

resource "aws_iam_role" "backend_api" {
  name = "${var.name_prefix}-backend-api-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}


resource "aws_iam_role_policy" "backend_api" {
  name = "backend-api"
  role = aws_iam_role.backend_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Jobs"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Scan", ##stats: conteggi per la dashboard web
        ]
        Resource = aws_dynamodb_table.jobs.arn
      },
      {
        ##stats: serie giornaliera dei costi dalle metriche EMF
        ##(GetMetricData non supporta resource-level permissions)
        Sid      = "ReadMetrics"
        Effect   = "Allow"
        Action   = "cloudwatch:GetMetricData"
        Resource = "*"
      },
      {
        ##needed to sign presigned PUT URLs for the cv/ prefix
        Sid      = "PresignUpload"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${var.cv_bucket_arn}/cv/*"
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
      {
        Sid    = "Xray"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
        ]
        Resource = "*"
      },
    ]
  })
}
