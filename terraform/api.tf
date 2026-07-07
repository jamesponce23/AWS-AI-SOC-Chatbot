#################################################
# REST API
#################################################
resource "aws_api_gateway_rest_api" "soc_api" {
  name        = "soc-copilot-api"
  description = "API for SOC Copilot"
}

#################################################
# Root GET method
#################################################
resource "aws_api_gateway_method" "root_get" {
  rest_api_id      = aws_api_gateway_rest_api.soc_api.id
  resource_id      = aws_api_gateway_rest_api.soc_api.root_resource_id
  http_method      = "GET"
  authorization    = "COGNITO_USER_POOLS"
  authorizer_id    = aws_api_gateway_authorizer.cognito.id
  api_key_required = true
}

resource "aws_api_gateway_integration" "root_get_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.soc_api.id
  resource_id             = aws_api_gateway_rest_api.soc_api.root_resource_id
  http_method             = aws_api_gateway_method.root_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.analyzer.invoke_arn
}

#################################################
# /analyze resource
#################################################
resource "aws_api_gateway_resource" "analyze" {
  rest_api_id = aws_api_gateway_rest_api.soc_api.id
  parent_id   = aws_api_gateway_rest_api.soc_api.root_resource_id
  path_part   = "analyze"
}

#################################################
# POST method for /analyze
#################################################
resource "aws_api_gateway_method" "post_method" {
  rest_api_id      = aws_api_gateway_rest_api.soc_api.id
  resource_id      = aws_api_gateway_resource.analyze.id
  http_method      = "POST"
  authorization    = "COGNITO_USER_POOLS"
  authorizer_id    = aws_api_gateway_authorizer.cognito.id
  api_key_required = true
}

resource "aws_api_gateway_method_response" "post_method_response" {
  rest_api_id = aws_api_gateway_rest_api.soc_api.id
  resource_id = aws_api_gateway_resource.analyze.id
  http_method = aws_api_gateway_method.post_method.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.soc_api.id
  resource_id             = aws_api_gateway_resource.analyze.id
  http_method             = aws_api_gateway_method.post_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.query_api.invoke_arn
}

resource "aws_api_gateway_integration_response" "post_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.soc_api.id
  resource_id = aws_api_gateway_resource.analyze.id
  http_method = aws_api_gateway_method.post_method.http_method
  status_code = aws_api_gateway_method_response.post_method_response.status_code

  response_parameters = {
    # Locked to the chat UI's CloudFront origin instead of "*".
    "method.response.header.Access-Control-Allow-Origin" = "'https://${aws_cloudfront_distribution.chat_ui.domain_name}'"
  }
}

#################################################
# OPTIONS method for CORS
#################################################
resource "aws_api_gateway_method" "options_method" {
  rest_api_id   = aws_api_gateway_rest_api.soc_api.id
  resource_id   = aws_api_gateway_resource.analyze.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_integration" {
  rest_api_id          = aws_api_gateway_rest_api.soc_api.id
  resource_id          = aws_api_gateway_resource.analyze.id
  http_method          = aws_api_gateway_method.options_method.http_method
  type                 = "MOCK"
  passthrough_behavior = "WHEN_NO_MATCH"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
 }
}

resource "aws_api_gateway_method_response" "options_response" {
  rest_api_id = aws_api_gateway_rest_api.soc_api.id
  resource_id = aws_api_gateway_resource.analyze.id
  http_method = aws_api_gateway_method.options_method.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.soc_api.id
  resource_id = aws_api_gateway_resource.analyze.id
  http_method = aws_api_gateway_method.options_method.http_method
  status_code = aws_api_gateway_method_response.options_response.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,POST,GET'"
    # Locked to the chat UI's CloudFront origin instead of "*".
    "method.response.header.Access-Control-Allow-Origin"  = "'https://${aws_cloudfront_distribution.chat_ui.domain_name}'"
  }
}

#################################################
# Deployment
#################################################
resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.soc_api.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_method.root_get,
      aws_api_gateway_method.post_method,
    ]))
  }

  depends_on = [
    aws_api_gateway_integration.lambda_integration,
    aws_api_gateway_integration_response.post_integration_response,
    aws_api_gateway_integration_response.options_integration_response
  ]

  lifecycle {
    create_before_destroy = true
  }
}

#################################################
# Stage: dev
#################################################
resource "aws_api_gateway_stage" "dev_stage" {
  stage_name    = "dev"
  rest_api_id   = aws_api_gateway_rest_api.soc_api.id
  deployment_id = aws_api_gateway_deployment.deployment.id
  description   = "Development stage for SOC Copilot"
}

#################################################
# Stage: prod
#################################################
resource "aws_api_gateway_stage" "prod_stage" {
  stage_name    = "prod"
  rest_api_id   = aws_api_gateway_rest_api.soc_api.id
  deployment_id = aws_api_gateway_deployment.deployment.id
  description   = "Production stage for SOC Copilot"
}

#################################################
# Lambda permissions
#################################################
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.analyzer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.soc_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_query" {
  statement_id  = "AllowAPIGatewayInvokeQuery"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.query_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.soc_api.execution_arn}/*/*"
}

#################################################
# API Key
#################################################
resource "aws_api_gateway_api_key" "soc_api_key" {
  name    = "soc-copilot-api-key"
  enabled = true
}

#################################################
# Usage Plan (rate limiting + quota)
#################################################
resource "aws_api_gateway_usage_plan" "soc_usage_plan" {
  name = "soc-copilot-usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.soc_api.id
    stage  = aws_api_gateway_stage.dev_stage.stage_name
  }

  api_stages {
    api_id = aws_api_gateway_rest_api.soc_api.id
    stage  = aws_api_gateway_stage.prod_stage.stage_name
  }

  throttle_settings {
    rate_limit  = 10
    burst_limit = 20
  }

  quota_settings {
    limit  = 1000
    period = "DAY"
  }
}

resource "aws_api_gateway_usage_plan_key" "soc_usage_plan_key" {
  key_id        = aws_api_gateway_api_key.soc_api_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.soc_usage_plan.id
}

#################################################
# Outputs
#################################################
output "chat_ui_api_url_dev" {
  value = "${aws_api_gateway_stage.dev_stage.invoke_url}/analyze"
}

output "chat_ui_api_url_prod" {
  value = "${aws_api_gateway_stage.prod_stage.invoke_url}/analyze"
}

output "api_url_dev" {
  description = "Dev base URL for SOC Copilot API"
  value       = aws_api_gateway_stage.dev_stage.invoke_url
}

output "api_url_prod" {
  description = "Production base URL for SOC Copilot API"
  value       = aws_api_gateway_stage.prod_stage.invoke_url
}

output "api_key_value" {
  description = "SOC Copilot API key — add to x-api-key header in frontend"
  value       = aws_api_gateway_api_key.soc_api_key.value
  sensitive   = true
}