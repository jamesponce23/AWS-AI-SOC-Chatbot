# ============================================================
# SOCCopilotDeployer — least-privilege policy sufficient to
# deploy THIS stack (+ manage remote state). Attached to both
# the human IAM user (terraform-user) and the GitHub OIDC
# deploy role. Lets us drop the terraform-users-group full
# access (EC2/RDS/Route53/etc). Scoped to soc-copilot-* /
# SOCAnalysis resources where AWS allows it; a few services
# (CloudFront, Cognito, API Gateway) have no create-time
# resource scoping so they stay "*".
# ============================================================
locals {
  acct = data.aws_caller_identity.current.account_id
}

resource "aws_iam_policy" "deployer" {
  name        = "SOCCopilotDeployer"
  description = "Least-privilege deploy permissions for the SOC Copilot stack + TF state"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "S3StackAndState",
        Effect = "Allow",
        Action = ["s3:*"],
        Resource = [
          "arn:aws:s3:::soc-copilot-*",
          "arn:aws:s3:::soc-copilot-*/*"
        ]
      },
      {
        Sid      = "S3GlobalList",
        Effect   = "Allow",
        Action   = ["s3:ListAllMyBuckets", "s3:GetBucketLocation"],
        Resource = "*"
      },
      {
        Sid    = "DynamoStack",
        Effect = "Allow",
        Action = ["dynamodb:*"],
        Resource = [
          "arn:aws:dynamodb:us-east-1:${local.acct}:table/SOCAnalysis",
          "arn:aws:dynamodb:us-east-1:${local.acct}:table/SOCAnalysis/index/*"
        ]
      },
      {
        Sid      = "DynamoGlobalList",
        Effect   = "Allow",
        Action   = ["dynamodb:ListTables", "dynamodb:DescribeLimits"],
        Resource = "*"
      },
      {
        Sid      = "Lambda",
        Effect   = "Allow",
        Action   = ["lambda:*"],
        Resource = "arn:aws:lambda:us-east-1:${local.acct}:function:soc-copilot-*"
      },
      {
        Sid      = "LambdaGlobalList",
        Effect   = "Allow",
        Action   = ["lambda:GetAccountSettings", "lambda:ListFunctions"],
        Resource = "*"
      },
      {
        Sid    = "IamManageStackPrincipals",
        Effect = "Allow",
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole",
          "iam:TagRole", "iam:UntagRole",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:PutRolePermissionsBoundary", "iam:DeleteRolePermissionsBoundary",
          "iam:CreatePolicy", "iam:DeletePolicy",
          "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
          "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions",
          "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:TagOpenIDConnectProvider"
        ],
        Resource = [
          "arn:aws:iam::${local.acct}:role/soc-copilot-*",
          "arn:aws:iam::${local.acct}:policy/SOCCopilot*",
          "arn:aws:iam::${local.acct}:policy/soc-copilot-*",
          "arn:aws:iam::${local.acct}:oidc-provider/token.actions.githubusercontent.com"
        ]
      },
      {
        Sid      = "IamReadOnly",
        Effect   = "Allow",
        Action   = ["iam:Get*", "iam:List*"],
        Resource = "*"
      },
      {
        Sid      = "IamPassLambdaRole",
        Effect   = "Allow",
        Action   = ["iam:PassRole"],
        Resource = "arn:aws:iam::${local.acct}:role/soc-copilot-lambda-role",
        Condition = {
          StringEquals = { "iam:PassedToService" = "lambda.amazonaws.com" }
        }
      },
      {
        Sid      = "CloudTrail",
        Effect   = "Allow",
        Action   = ["cloudtrail:*"],
        Resource = "*"
      },
      {
        Sid      = "CloudFront",
        Effect   = "Allow",
        Action   = ["cloudfront:*"],
        Resource = "*"
      },
      {
        Sid      = "Cognito",
        Effect   = "Allow",
        Action   = ["cognito-idp:*"],
        Resource = "*"
      },
      {
        Sid      = "ApiGateway",
        Effect   = "Allow",
        Action   = ["apigateway:*"],
        Resource = "*"
      },
      {
        Sid    = "LambdaLogGroups",
        Effect = "Allow",
        Action = ["logs:*"],
        Resource = [
          "arn:aws:logs:us-east-1:${local.acct}:log-group:/aws/lambda/soc-copilot-*",
          "arn:aws:logs:us-east-1:${local.acct}:log-group:/aws/lambda/soc-copilot-*:*"
        ]
      },
      {
        Sid      = "LogsDescribe",
        Effect   = "Allow",
        Action   = ["logs:DescribeLogGroups"],
        Resource = "*"
      }
    ]
  })
}

# Additive attachment to the human deployer — safe, grants nothing
# they don't already have via the group. Detaching the group later
# is what actually tightens (see the gated manual step).
resource "aws_iam_user_policy_attachment" "deployer_user" {
  user       = "terraform-user"
  policy_arn = aws_iam_policy.deployer.arn
}
