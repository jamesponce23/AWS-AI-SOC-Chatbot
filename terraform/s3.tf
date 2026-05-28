#################################################
# RANDOM IDS
#################################################

resource "random_id" "logs" {
  byte_length = 4
}

resource "random_id" "ui" {
  byte_length = 4
}

#################################################
# CLOUDTRAIL LOGS BUCKET (PRIVATE)
#################################################

resource "aws_s3_bucket" "logs" {
  bucket = "soc-copilot-logs-${random_id.logs.hex}"
}

resource "aws_s3_bucket_policy" "cloudtrail_policy" {
  bucket = aws_s3_bucket.logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.logs.arn
      },
      {
        Sid = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.logs.arn}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

#################################################
# CHAT UI BUCKET (PRIVATE)
#################################################

resource "aws_s3_bucket" "chat_ui" {
  bucket = "soc-copilot-ui-${random_id.ui.hex}"
}

resource "aws_s3_object" "chat_index" {
  bucket       = aws_s3_bucket.chat_ui.id
  key          = "index.html"
  source       = "/home/system_admin23/AI SOC Agent/terraform/chat_ui/index.html"
  content_type = "text/html"
  etag         = filemd5("/home/system_admin23/AI SOC Agent/terraform/chat_ui/index.html")
}

resource "aws_s3_object" "chat_script" {
  bucket       = aws_s3_bucket.chat_ui.id
  key          = "script.js"
  source       = "/home/system_admin23/AI SOC Agent/terraform/chat_ui/script.js"
  content_type = "application/javascript"
  etag         = filemd5("/home/system_admin23/AI SOC Agent/terraform/chat_ui/script.js")
}

#################################################
# CLOUDFRONT SECURE ACCESS
#################################################

resource "aws_cloudfront_origin_access_control" "chat_ui" {
  name                              = "soc-copilot-oac"
  description                       = "Secure access to private S3"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_policy" "chat_ui_private" {
  bucket = aws_s3_bucket.chat_ui.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "cloudfront.amazonaws.com"
      }
      Action   = "s3:GetObject"
      Resource = "${aws_s3_bucket.chat_ui.arn}/*"
    }]
  })
}

resource "aws_cloudfront_distribution" "chat_ui" {
  enabled             = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.chat_ui.bucket_regional_domain_name
    origin_id                = "chat-ui"
    origin_access_control_id = aws_cloudfront_origin_access_control.chat_ui.id
  }

  default_cache_behavior {
    target_origin_id       = "chat-ui"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

#################################################
# OUTPUT
#################################################

output "chat_ui_url" {
  value = "https://${aws_cloudfront_distribution.chat_ui.domain_name}"
}
