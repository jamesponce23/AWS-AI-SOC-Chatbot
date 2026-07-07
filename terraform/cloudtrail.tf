resource "aws_cloudtrail" "trail" {
  name           = "soc-copilot-trail"
  s3_bucket_name = aws_s3_bucket.logs.id

  include_global_service_events = true
  is_multi_region_trail         = true

  # Detect tampering with the trail's own log files.
  enable_log_file_validation = true

  depends_on = [
    aws_s3_bucket_policy.cloudtrail_policy
  ]
}
