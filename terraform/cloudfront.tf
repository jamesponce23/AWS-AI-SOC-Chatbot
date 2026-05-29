resource "aws_cloudfront_distribution" "soc_api" {
  enabled = true
  comment = "SOC Copilot — injects API key so browser never sees it"

  origin {
    domain_name = "${aws_api_gateway_rest_api.soc_api.id}.execute-api.us-east-1.amazonaws.com"
    origin_id   = "soc-api-gateway"
    origin_path = "/${aws_api_gateway_stage.prod_stage.stage_name}"

    # API key lives here in AWS config — never sent to or stored in the browser
    custom_header {
      name  = "x-api-key"
      value = aws_api_gateway_api_key.soc_api_key.value
    }

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "soc-api-gateway"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      headers      = ["Origin", "Access-Control-Request-Headers", "Access-Control-Request-Method"]

      cookies {
        forward = "none"
      }
    }

    # No caching — every query must reach Lambda
    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
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

output "cloudfront_url" {
  description = "Use this as API_ENDPOINT in the frontend instead of the direct API Gateway URL"
  value       = "https://${aws_cloudfront_distribution.soc_api.domain_name}"
}
