##vector store (doc 4.6, scelta v0: Aurora pgvector). Serverless v2
##con min 0 ACU (scala a zero a riposo) e RDS Data API attiva: le
##lambda NON stanno in VPC — parlano col cluster via Data API (IAM),
##quindi niente NAT ne' ENI. Vedi ADR-006

##--- rete minima: il cluster vuole un subnet group su 2 AZ ----------

resource "aws_vpc" "vectorstore" {
  cidr_block = "10.20.0.0/24"

  tags = { Name = "${local.name_prefix}-vectorstore" }
}

resource "aws_subnet" "vectorstore_a" {
  vpc_id            = aws_vpc.vectorstore.id
  cidr_block        = "10.20.0.0/26"
  availability_zone = "eu-central-1a"

  tags = { Name = "${local.name_prefix}-vectorstore-a" }
}

resource "aws_subnet" "vectorstore_b" {
  vpc_id            = aws_vpc.vectorstore.id
  cidr_block        = "10.20.0.64/26"
  availability_zone = "eu-central-1b"

  tags = { Name = "${local.name_prefix}-vectorstore-b" }
}

resource "aws_db_subnet_group" "vectorstore" {
  name       = "${local.name_prefix}-vectorstore"
  subnet_ids = [aws_subnet.vectorstore_a.id, aws_subnet.vectorstore_b.id]
}

##nessun ingress: l'unico accesso e' la Data API, che non passa dalla rete
resource "aws_security_group" "vectorstore" {
  name        = "${local.name_prefix}-vectorstore"
  description = "Aurora vector store - no network access, Data API only"
  vpc_id      = aws_vpc.vectorstore.id
}

##--- cluster Aurora Serverless v2 -----------------------------------

resource "aws_rds_cluster" "vectorstore" {
  cluster_identifier = "${local.name_prefix}-vectorstore"

  engine         = "aurora-postgresql"
  engine_mode    = "provisioned"
  engine_version = "17.9"
  database_name  = "skillbridge"

  ##credenziali master gestite da RDS su Secrets Manager: la Data API
  ##si autentica con quel secret, nessuna password nel codice
  master_username             = "postgres"
  manage_master_user_password = true

  ##Data API v2
  enable_http_endpoint = true

  serverlessv2_scaling_configuration {
    min_capacity = 0 ##scala a zero a riposo (resume ~15s)
    max_capacity = 2
  }

  db_subnet_group_name   = aws_db_subnet_group.vectorstore.name
  vpc_security_group_ids = [aws_security_group.vectorstore.id]

  storage_encrypted   = true
  skip_final_snapshot = true ##ambiente dev
}

resource "aws_rds_cluster_instance" "vectorstore" {
  cluster_identifier = aws_rds_cluster.vectorstore.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.vectorstore.engine
  engine_version     = aws_rds_cluster.vectorstore.engine_version
}

output "vectorstore_cluster_arn" {
  value = aws_rds_cluster.vectorstore.arn
}

output "vectorstore_secret_arn" {
  value = aws_rds_cluster.vectorstore.master_user_secret[0].secret_arn
}
