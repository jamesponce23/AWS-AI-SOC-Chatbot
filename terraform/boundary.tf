# ============================================================
# b1 — Permission boundary for the Lambda execution role.
# A boundary caps the MAX permissions the role can ever have
# (effective perms = role policies ∩ boundary). This must be a
# superset of everything the Lambda actually uses, or the
# function loses access. Keep it in lock-step with iam.tf.
# ============================================================
resource "aws_iam_policy" "lambda_boundary" {
  name        = "soc-copilot-lambda-boundary"
  description = "Permission boundary capping the SOC Copilot Lambda execution role"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "Logs",
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Sid      = "ReadLogBucket",
        Effect   = "Allow",
        Action   = ["s3:GetObject"],
        Resource = "${aws_s3_bucket.logs.arn}/*"
      },
      {
        Sid      = "InvokeModel",
        Effect   = "Allow",
        Action   = ["bedrock:InvokeModel"],
        Resource = "arn:aws:bedrock:us-east-1::foundation-model/meta.llama3-70b-instruct-v1:0"
      },
      {
        Sid    = "AnalysisTable",
        Effect = "Allow",
        Action = [
          "dynamodb:Scan",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query"
        ],
        Resource = [
          aws_dynamodb_table.soc_analysis.arn,
          "${aws_dynamodb_table.soc_analysis.arn}/index/*"
        ]
      }
    ]
  })
}
