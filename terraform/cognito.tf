#################################################
# Helper data sources
# aws_caller_identity.current is already declared in main.tf, so it is reused.
#################################################
data "aws_region" "current" {}

#################################################
# Cognito User Pool
#################################################
resource "aws_cognito_user_pool" "soc" {
  name = "soc-copilot-users"

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  auto_verified_attributes = ["email"]
  mfa_configuration        = "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # SOC tool = internal. No open sign-up; admins provision users.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }
}

#################################################
# Hosted UI domain (for the login screen)
# Domain must be globally unique across all AWS accounts, so we suffix
# with the account ID (globally unique, lowercase-alphanumeric — valid).
#################################################
resource "aws_cognito_user_pool_domain" "soc" {
  domain       = "soc-copilot-auth-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.soc.id
}

#################################################
# App client — PUBLIC (no secret), for the browser SPA
#################################################
resource "aws_cognito_user_pool_client" "soc_web" {
  name         = "soc-copilot-web"
  user_pool_id = aws_cognito_user_pool.soc.id

  # No client secret: a browser cannot keep a secret, so this is a public
  # client using the Authorization Code flow + PKCE.
  generate_secret = false

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  # Points at the chat UI's own CloudFront root. The SPA handles the
  # ?code=... on load (no separate /callback object exists in the bucket).
  callback_urls = ["https://${aws_cloudfront_distribution.chat_ui.domain_name}/"]
  logout_urls   = ["https://${aws_cloudfront_distribution.chat_ui.domain_name}/"]

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

#################################################
# API Gateway Cognito authorizer
# Referenced by the methods in api.tf via authorizer_id.
#################################################
resource "aws_api_gateway_authorizer" "cognito" {
  name            = "soc-cognito-authorizer"
  type            = "COGNITO_USER_POOLS"
  rest_api_id     = aws_api_gateway_rest_api.soc_api.id
  provider_arns   = [aws_cognito_user_pool.soc.arn]
  identity_source = "method.request.header.Authorization"
}

#################################################
# Outputs the frontend needs (none are secret)
#################################################
output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.soc.id
}

output "cognito_web_client_id" {
  value = aws_cognito_user_pool_client.soc_web.id
}

output "cognito_hosted_ui_domain" {
  value = "${aws_cognito_user_pool_domain.soc.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
}
