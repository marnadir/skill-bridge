
resource "aws_iam_role" "step" {
  for_each = local.step_lambdas

  ##CONSTRAINT: role names must start with skillbridge-*
  name = "${var.name_prefix}-${each.key}-lambda"

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
      [local.bedrock_statement, local.logs_statement, local.xray_statement],
    )
  })
}

##--- state machine ---------------------------------------------------

##CONSTRAINT: role names must start with skillbridge-*
resource "aws_iam_role" "cv_processing_sfn" {
  name = "${var.name_prefix}-cv-processing-sfn"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}


##the state machine can only invoke the step lambdas and update the
##job state
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
        ##every outcome updates the job state (doc 2.2)
        Sid      = "UpdateJobStatus"
        Effect   = "Allow"
        Action   = "dynamodb:UpdateItem"
        Resource = var.jobs_table_arn
      },
      {
        Sid    = "Xray"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
        ]
        Resource = "*"
      },
    ]
  })
}


##--- consumer lambda ------------------------------------------------

resource "aws_iam_role" "start_cv_processing" {
  name = "${var.name_prefix}-start-cv-processing-lambda"

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
        ##idempotency: conditional PENDING_UPLOAD -> PROCESSING transition
        Sid      = "ClaimJob"
        Effect   = "Allow"
        Action   = "dynamodb:UpdateItem"
        Resource = var.jobs_table_arn
      },
      local.logs_statement,
      local.xray_statement,
    ]
  })
}

##--- isolated executor of the external tool (doc 5.2-bis) -----------

##the security boundary is one of PERMISSIONS: logs only — no S3, no
##profile data, no index. The isolation is provable, not declared
resource "aws_iam_role" "tool_validate_employer" {
  name = "${var.name_prefix}-tool-validate-employer-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "tool_validate_employer" {
  name = "tool-validate-employer"
  role = aws_iam_role.tool_validate_employer.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [local.logs_statement, local.xray_statement]
  })
}
