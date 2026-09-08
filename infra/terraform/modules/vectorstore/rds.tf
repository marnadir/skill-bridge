
resource "aws_db_subnet_group" "vectorstore" {
  name       = "${var.name_prefix}-vectorstore"
  subnet_ids = [aws_subnet.vectorstore_a.id, aws_subnet.vectorstore_b.id]
}


##--- Aurora Serverless v2 cluster -----------------------------------

resource "aws_rds_cluster" "vectorstore" {
  cluster_identifier = "${var.name_prefix}-vectorstore"

  engine         = "aurora-postgresql"
  engine_mode    = "provisioned"
  engine_version = var.engine_version
  database_name  = var.database_name

  ##master credentials managed by RDS on Secrets Manager: the Data
  ##API authenticates with that secret, no password in code
  master_username             = "postgres"
  manage_master_user_password = true

  ##Data API v2
  enable_http_endpoint = true

  serverlessv2_scaling_configuration {
    min_capacity = var.min_capacity ##0 = scales to zero (resume ~15s)
    max_capacity = var.max_capacity
  }

  db_subnet_group_name   = aws_db_subnet_group.vectorstore.name
  vpc_security_group_ids = [aws_security_group.vectorstore.id]

  storage_encrypted   = true
  skip_final_snapshot = var.skip_final_snapshot
}


resource "aws_rds_cluster_instance" "vectorstore" {
  cluster_identifier = aws_rds_cluster.vectorstore.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.vectorstore.engine
  engine_version     = aws_rds_cluster.vectorstore.engine_version
}
