##backend API (doc 3.1): API Gateway HTTP API + backend-api lambda.
##POST /jobs creates the job on DynamoDB and returns the presigned
##URL; GET /jobs/{jobId} is the web app status polling

data "aws_caller_identity" "current" {}

##--- jobs table: source of truth of the job state -------------------

resource "aws_dynamodb_table" "jobs" {
  name         = "${var.name_prefix}-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }
}
