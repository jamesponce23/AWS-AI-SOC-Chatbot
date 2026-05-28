resource "aws_lambda_function" "analyzer" {
  function_name = "soc-copilot-analyzer"
  role          = aws_iam_role.lambda_role.arn
  handler       = "app.handler"
  runtime       = "python3.12"
  timeout       = 180
  memory_size   = 256

  filename         = "/home/system_admin23/AI SOC Agent/terraform/lambda/function.zip"
  source_code_hash = filebase64sha256("/home/system_admin23/AI SOC Agent/terraform/lambda/function.zip")

  # ============================
  # Add environment variable
  # ============================
  environment {
    variables = {
      DDB_TABLE = aws_dynamodb_table.soc_analysis.name
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

  filename         = "/home/system_admin23/AI SOC Agent/terraform/lambda/query_function.zip"
  source_code_hash = filebase64sha256("/home/system_admin23/AI SOC Agent/terraform/lambda/query_function.zip")

  environment {
    variables = {
      DDB_TABLE = aws_dynamodb_table.soc_analysis.name
    }
  }
}
 
