##vector store (doc 4.6, v0 choice: Aurora pgvector). Serverless v2
##with min 0 ACU (scales to zero at rest) and RDS Data API: lambdas
##are NOT in the VPC — they talk to the cluster via Data API (IAM),
##so no NAT and no ENIs. See ADR-006

##--- minimal network: the cluster requires a 2-AZ subnet group ------

resource "aws_vpc" "vectorstore" {
  cidr_block = var.vpc_cidr

  tags = { Name = "${var.name_prefix}-vectorstore" }
}


resource "aws_subnet" "vectorstore_a" {
  vpc_id            = aws_vpc.vectorstore.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 2, 0)
  availability_zone = var.availability_zones[0]

  tags = { Name = "${var.name_prefix}-vectorstore-a" }
}


resource "aws_subnet" "vectorstore_b" {
  vpc_id            = aws_vpc.vectorstore.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 2, 1)
  availability_zone = var.availability_zones[1]

  tags = { Name = "${var.name_prefix}-vectorstore-b" }
}


##no ingress: the only access path is the Data API, which bypasses
##the network entirely
resource "aws_security_group" "vectorstore" {
  name        = "${var.name_prefix}-vectorstore"
  description = "Aurora vector store - no network access, Data API only"
  vpc_id      = aws_vpc.vectorstore.id
}
