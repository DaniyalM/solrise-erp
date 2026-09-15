# =============================================================================
# GitHub Actions -> ECR via OIDC (no long-lived AWS keys in GitHub).
#
# The workflow assumes `github_actions_role_arn` using the repo's OIDC identity.
# The trust policy is locked to one repository and one ref, so a fork or another
# branch cannot assume the role.
#
# Skip all of this if the account already has a GitHub OIDC provider and you
# prefer to manage the CI role yourself: set create_github_oidc_provider = false
# and github_oidc_provider_arn = "..." .
# =============================================================================

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? try(aws_iam_openid_connect_provider.github[0].arn, "") : var.github_oidc_provider_arn
  enable_github_oidc       = var.enable_ecr && var.github_repository != ""
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates against its trust store now; the value is retained for
  # providers that still expect it.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = { Name = "${local.name}-github-oidc" }
}

data "aws_iam_policy_document" "github_assume" {
  count = local.enable_github_oidc ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # repo:owner/name:ref:refs/heads/main
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:${var.github_oidc_branch}"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  count = local.enable_github_oidc ? 1 : 0

  name               = "${local.name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_assume[0].json

  tags = { Name = "${local.name}-github-actions" }
}

data "aws_iam_policy_document" "github_ecr_push" {
  count = local.enable_github_oidc ? 1 : 0

  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPush"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
    ]

    resources = [aws_ecr_repository.app[0].arn]
  }
}

resource "aws_iam_role_policy" "github_ecr_push" {
  count = local.enable_github_oidc ? 1 : 0

  name   = "ecr-push"
  role   = aws_iam_role.github_actions[0].id
  policy = data.aws_iam_policy_document.github_ecr_push[0].json
}
