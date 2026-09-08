
##--- PII map (token -> identity, separate from pipeline data) -------

resource "aws_dynamodb_table" "pii_map" {
  name         = "${var.name_prefix}-pii-map"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }
}
