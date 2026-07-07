terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

resource "aws_dynamodb_table" "soc_analysis" {
  name         = "SOCAnalysis"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "EventId"

  # Encrypt findings at rest and allow recovery of tampered/deleted data.
  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  ttl {
    attribute_name = "TTL"
    enabled        = true
  }

  attribute {
    name = "EventId"
    type = "S"
  }

  attribute {
    name = "Source"
    type = "S"
  }

  attribute {
    name = "Timestamp"
    type = "S"
  }

  global_secondary_index {
    name            = "Source-Timestamp-Index"
    hash_key        = "Source"
    range_key       = "Timestamp"
    projection_type = "ALL"
  }
}