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
    "public-a" = { cidr = "10.0.1.0/24", az = "us-west-2a" }
    "public-b" = { cidr = "10.0.2.0/24", az = "us-west-2b" }
    "app-a"    = { cidr = "10.0.11.0/24", az = "us-west-2a" }
    "app-b"    = { cidr = "10.0.12.0/24", az = "us-west-2b" }
    "db-a"     = { cidr = "10.0.21.0/24", az = "us-west-2a" }
    "db-b"     = { cidr = "10.0.22.0/24", az = "us-west-2b" }
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