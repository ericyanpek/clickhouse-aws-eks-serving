data "aws_eks_cluster" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

# The OIDC provider is already created by the blueprint's EKS module (enable_irsa).
# Reference it as a DATA source — creating a new one collides (EntityAlreadyExists).
data "aws_iam_openid_connect_provider" "this" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

# One backup role per cluster that enables backup. A single shared role would let
# any cluster's sidecar assume credentials for the whole bucket; scoping the role to
# one namespace's ServiceAccount and one S3 prefix keeps the blast radius per cluster.
locals {
  backup_clusters = { for k, v in var.clickhouse_clusters : k => v if v.enable_backup }
}

data "aws_iam_policy_document" "backup_assume" {
  for_each = local.backup_clusters

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.this.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.this.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:ck-${each.key}:clickhouse-backup"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.this.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  for_each = local.backup_clusters

  name               = "${var.cluster_name}-ck-${each.key}-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume[each.key].json
}

data "aws_iam_policy_document" "backup_s3" {
  for_each = local.backup_clusters

  # Object access is confined to this cluster's prefix.
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.backup.arn}/${each.key}/*"]
  }

  # ListBucket and GetBucketLocation can only target the bucket ARN itself (they are
  # bucket-level actions), so the prefix restriction moves into a condition —
  # without it a cluster could enumerate every other cluster's backup keys.
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backup.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${each.key}/*"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = [aws_s3_bucket.backup.arn]
  }
}

resource "aws_iam_role_policy" "backup_s3" {
  for_each = local.backup_clusters

  name   = "s3-access"
  role   = aws_iam_role.backup[each.key].id
  policy = data.aws_iam_policy_document.backup_s3[each.key].json
}
