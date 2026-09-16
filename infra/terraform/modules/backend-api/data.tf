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

  attribute {
    name = "created_by"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  ##"my jobs" listing (GET /jobs): query by owner, newest first.
  ##INCLUDE projection keeps the index lean: the heavy "results"
  ##attribute stays out, the detail comes from GET /jobs/{jobId}
  global_secondary_index {
    name               = "created_by-index"
    hash_key           = "created_by"
    range_key          = "created_at"
    projection_type    = "INCLUDE"
    non_key_attributes = ["status", "file_name", "updated_at"]
  }
}
