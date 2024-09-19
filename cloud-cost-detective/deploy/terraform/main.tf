###############################################################################
# Least-privilege IAM for Cloud Cost Detective.
#
# Creates a read-only Cost Explorer role assumable two ways:
#   1. GitHub Actions via OIDC   (no static access keys in CI)
#   2. an EKS service account via IRSA (for the CronJob in deploy/kubernetes)
#
# Usage:
#   terraform init
#   terraform apply -var 'github_repo=your-org/cloud-cost-detective'
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "name" {
  description = "Name prefix for the created resources."
  type        = string
  default     = "cost-detective"
}

variable "github_repo" {
  description = "GitHub repository allowed to assume the role, as owner/name."
  type        = string
  default     = ""
}

variable "github_branch" {
  description = "Branch permitted to assume the role. Wildcards are accepted but scope them tightly."
  type        = string
  default     = "main"
}

variable "eks_oidc_provider_arn" {
  description = "OIDC provider ARN of the EKS cluster, for IRSA. Leave empty to skip."
  type        = string
  default     = ""
}

variable "eks_namespace" {
  description = "Namespace of the CronJob service account."
  type        = string
  default     = "finops"
}

variable "eks_service_account" {
  description = "Name of the CronJob service account."
  type        = string
  default     = "cost-detective"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Component = "finops"
  }
}

locals {
  create_github = var.github_repo != ""
  create_irsa   = var.eks_oidc_provider_arn != ""
}

data "aws_caller_identity" "current" {}

###############################################################################
# GitHub Actions OIDC provider
#
# Only created if one does not already exist in the account — GitHub's provider
# is account-global, so a second one will fail. Import the existing provider if
# you already have it: terraform import aws_iam_openid_connect_provider.github <arn>
###############################################################################

resource "aws_iam_openid_connect_provider" "github" {
  count = local.create_github ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # AWS validates the OIDC endpoint's certificate chain itself; this thumbprint
  # is retained for backwards compatibility only.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = var.tags
}

###############################################################################
# Trust policy
###############################################################################

data "aws_iam_policy_document" "assume" {
  # --- GitHub Actions ---
  dynamic "statement" {
    for_each = local.create_github ? [1] : []

    content {
      effect  = "Allow"
      actions = ["sts:AssumeRoleWithWebIdentity"]

      principals {
        type        = "Federated"
        identifiers = [aws_iam_openid_connect_provider.github[0].arn]
      }

      condition {
        test     = "StringEquals"
        variable = "token.actions.githubusercontent.com:aud"
        values   = ["sts.amazonaws.com"]
      }

      # Scoping to `sub` is what stops any repository on GitHub from assuming
      # this role. Never relax this to a bare wildcard.
      condition {
        test     = "StringLike"
        variable = "token.actions.githubusercontent.com:sub"
        values = [
          "repo:${var.github_repo}:ref:refs/heads/${var.github_branch}",
          "repo:${var.github_repo}:pull_request",
        ]
      }
    }
  }

  # --- EKS IRSA ---
  dynamic "statement" {
    for_each = local.create_irsa ? [1] : []

    content {
      effect  = "Allow"
      actions = ["sts:AssumeRoleWithWebIdentity"]

      principals {
        type        = "Federated"
        identifiers = [var.eks_oidc_provider_arn]
      }

      condition {
        test     = "StringEquals"
        variable = "${replace(var.eks_oidc_provider_arn, "/^.*oidc-provider//", "")}:sub"
        values   = ["system:serviceaccount:${var.eks_namespace}:${var.eks_service_account}"]
      }
    }
  }
}

###############################################################################
# Permissions
#
# Deliberately minimal. The tool only ever reads: it never tags, terminates or
# modifies anything, so no write action belongs here.
###############################################################################

data "aws_iam_policy_document" "cost_read" {
  statement {
    sid    = "CostExplorerRead"
    effect = "Allow"
    actions = [
      "ce:GetCostAndUsage",
      "ce:GetCostAndUsageWithResources",
      "ce:GetDimensionValues",
      "ce:GetTags",
    ]
    # Cost Explorer does not support resource-level permissions.
    resources = ["*"]
  }

  statement {
    sid    = "DescribeResourcesForAttribution"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
      "rds:DescribeDBInstances",
      "rds:ListTagsForResource",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "cost_read" {
  name        = "${var.name}-read"
  description = "Read-only Cost Explorer and resource-tag access for Cloud Cost Detective."
  policy      = data.aws_iam_policy_document.cost_read.json
  tags        = var.tags
}

resource "aws_iam_role" "this" {
  name        = "${var.name}-reader"
  description = "Assumed by Cloud Cost Detective to read spend and resource tags."

  assume_role_policy = data.aws_iam_policy_document.assume.json

  # A short session is enough for a batch report and limits the blast radius
  # of a leaked token.
  max_session_duration = 3600

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.cost_read.arn
}

###############################################################################
# Outputs
###############################################################################

output "role_arn" {
  description = "Set this as the AWS_COST_READER_ROLE_ARN secret, and as the IRSA annotation on the CronJob service account."
  value       = aws_iam_role.this.arn
}

output "policy_arn" {
  description = "ARN of the read-only policy."
  value       = aws_iam_policy.cost_read.arn
}

output "account_id" {
  description = "Account the role was created in."
  value       = data.aws_caller_identity.current.account_id
}
