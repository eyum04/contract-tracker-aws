terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name    = "ct-tf-vpc"
    Project = "contract-tracker"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "ct-tf-igw"
  }
}

locals {
  subnets = {
    "public-a" = { cidr = "10.0.1.0/24", az = "us-west-2a", tier = "public" }
    "public-b" = { cidr = "10.0.2.0/24", az = "us-west-2b", tier = "public" }
    "app-a"    = { cidr = "10.0.11.0/24", az = "us-west-2a", tier = "app" }
    "app-b"    = { cidr = "10.0.12.0/24", az = "us-west-2b", tier = "app" }
    "db-a"     = { cidr = "10.0.21.0/24", az = "us-west-2a", tier = "db" }
    "db-b"     = { cidr = "10.0.22.0/24", az = "us-west-2b", tier = "db" }
  }
}

resource "aws_subnet" "subnets" {
  for_each = local.subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = {
    Name = "ct-tf-${each.key}"
  }
}

locals {
  tiers = ["public", "app", "db"]
}

resource "aws_route_table" "tiers" {
  for_each = toset(local.tiers)

  vpc_id = aws_vpc.main.id

  tags = {
    Name = "ct-tf-${each.key}-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.tiers["public"].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}
resource "aws_route_table_association" "subnets" {
  for_each = local.subnets

  subnet_id      = aws_subnet.subnets[each.key].id
  route_table_id = aws_route_table.tiers[each.value.tier].id
}

resource "aws_security_group" "alb" {
  name        = "ct-tf-alb-sg"
  description = "Load balancer: Http from the internet"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "ct-tf-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}
resource "aws_vpc_security_group_egress_rule" "alb_all_out" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "app" {
  name        = "ct-tf-app-sg"
  description = "App servers: 8080 from the load balancer only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "ct-tf-app-sg"
  }
}
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}
resource "aws_vpc_security_group_egress_rule" "app_all_out" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "db" {
  name        = "ct-tf-db-sg"
  description = "Database: 5432 from the app servers only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "ct-tf-db-sg"
  }
}
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_s3_bucket" "contracts" {
  bucket = var.bucket_name

  tags = {
    Name = "ct-tf-contracts"
  }
}
resource "aws_s3_bucket_public_access_block" "contracts" {
  bucket = aws_s3_bucket.contracts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_versioning" "contracts" {
  bucket = aws_s3_bucket.contracts.id

  versioning_configuration {
    status = "Enabled"
  }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "contracts" {
  bucket = aws_s3_bucket.contracts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "contracts" {
  bucket = aws_s3_bucket.contracts.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.contracts.arn,
        "${aws_s3_bucket.contracts.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.contracts]
}

resource "aws_iam_role" "app" {
  name = "ct-tf-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app_access" {
  name = "ct-tf-app-access"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ContractFiles"
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ]
      Resource = "${aws_s3_bucket.contracts.arn}/contracts/*"
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "ct-tf-app-profile"
  role = aws_iam_role.app.name
}