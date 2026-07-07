# ============================
# Package Lambda source at apply time so code edits actually deploy
# ============================
data "archive_file" "analyzer_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/app.py"
  output_path = "${path.module}/lambda/function.zip"
}

data "archive_file" "query_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/query_handler.py"
  output_path = "${path.module}/lambda/query_function.zip"
}

resource "aws_lambda_function" "analyzer" {
  function_name = "soc-copilot-analyzer"
  role          = aws_iam_role.lambda_role.arn
  handler       = "app.handler"
  runtime       = "python3.12"
  timeout       = 180
  memory_size   = 256

  filename         = data.archive_file.analyzer_zip.output_path
  source_code_hash = data.archive_file.analyzer_zip.output_base64sha256

  environment {
    variables = {
      DDB_TABLE      = aws_dynamodb_table.soc_analysis.name
      ALLOWED_ORIGIN = "https://${aws_cloudfront_distribution.chat_ui.domain_name}"
    }
  }
}

resource "aws_lambda_permission" "s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.analyzer.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.logs.arn
}

resource "aws_s3_bucket_notification" "trigger" {
  bucket = aws_s3_bucket.logs.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.analyzer.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.s3]
}

resource "aws_lambda_function" "query_api" {
  function_name = "soc-copilot-query"
  role          = aws_iam_role.lambda_role.arn
  handler       = "query_handler.handler"
  runtime       = "python3.12"
  timeout       = 180
  memory_size   = 256

  filename         = data.archive_file.query_zip.output_path
  source_code_hash = data.archive_file.query_zip.output_base64sha256

  environment {
    variables = {
      DDB_TABLE      = aws_dynamodb_table.soc_analysis.name
      ALLOWED_ORIGIN = "https://${aws_cloudfront_distribution.chat_ui.domain_name}"
    }
  }
}
