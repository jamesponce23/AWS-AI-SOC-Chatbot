# ============================================================
# b2 (part 2) — GitHub Actions OIDC deploy role.
# Lets CI assume a role via short-lived OIDC tokens — no
# long-lived AWS access keys stored in GitHub. Trust is scoped
# to one repo AND one branch (github_deploy_ref).
# ============================================================

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # AWS validates GitHub's OIDC cert against its trust store now,
  # but the argument is still required; this is GitHub's thumbprint.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only this repo + this branch may assume the role.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:${var.github_deploy_ref}"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "soc-copilot-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

resource "aws_iam_role_policy_attachment" "github_deploy" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = aws_iam_policy.deployer.arn
}

output "github_deploy_role_arn" {
  description = "Role ARN for the GitHub Actions OIDC deploy workflow"
  value       = aws_iam_role.github_deploy.arn
}
