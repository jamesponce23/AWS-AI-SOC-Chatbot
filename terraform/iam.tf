resource "aws_iam_role" "lambda_role" {
  name = "soc-copilot-lambda-role"

  # b1: cap this role's max permissions (see boundary.tf).
  permissions_boundary = aws_iam_policy.lambda_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "extra" {
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["s3:GetObject"],
        Resource = "${aws_s3_bucket.logs.arn}/*"
      },
      {
        Effect = "Allow",
        Action = ["bedrock:InvokeModel"],
        Resource = "arn:aws:bedrock:us-east-1::foundation-model/meta.llama3-70b-instruct-v1:0"
      }, 
      {
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
