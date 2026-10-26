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