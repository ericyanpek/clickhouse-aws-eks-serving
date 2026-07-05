data "aws_eks_cluster" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

# The OIDC provider is already created by the blueprint's EKS module (enable_irsa).
# Reference it as a DATA source — creating a new one collides (EntityAlreadyExists).
data "aws_iam_openid_connect_provider" "this" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

data "aws_iam_policy_document" "backup_assume" {
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
      values   = ["system:serviceaccount:${var.clickhouse_namespace}:clickhouse-backup"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.this.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.cluster_name}-clickhouse-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
}

data "aws_iam_policy_document" "backup_s3" {
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = [
      aws_s3_bucket.backup.arn,
      "${aws_s3_bucket.backup.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "backup_s3" {
  name   = "s3-access"
  role   = aws_iam_role.backup.id
  policy = data.aws_iam_policy_document.backup_s3.json
}
