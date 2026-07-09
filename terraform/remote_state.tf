# ============================================================
# b2 (part 1) — Remote Terraform state backend (S3).
# Locking is handled by S3 natively (backend use_lockfile in
# main.tf), so no DynamoDB lock table is needed. Managing the
# state bucket in the same state it stores is the standard
# bootstrap pattern — it works; you just can't destroy the
# bucket while using it.
# ============================================================

resource "aws_s3_bucket" "tfstate" {
  bucket = "soc-copilot-tfstate-${data.aws_caller_identity.current.account_id}"

  # State is the crown jewels — never accidentally destroy it.
  lifecycle {
    prevent_destroy = true
  }
}

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
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

