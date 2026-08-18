# 00-global
# 나머지 모든 레이어의 tfstate 를 담는 S3 버킷.
# 이 레이어만 닭-달걀 문제가 있어 로컬 state 로 apply 한 뒤,
# scripts/bootstrap.sh 가 자기 자신이 만든 버킷으로 state 를 migrate 합니다.

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = var.project
      Source  = "github.com/kwonci/stack/00-global"
      Managed = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  lifecycle {
    # 이 버킷을 잃으면 01/02 의 state 를 전부 잃습니다.
    # 정말 지워야 한다면 이 블록을 먼저 지우세요.
    prevent_destroy = true
  }
}

# state 파일을 실수로 지웠을 때 되돌릴 수 있는 유일한 안전장치입니다.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
