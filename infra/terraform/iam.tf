# =============================================================================
# Instance role. No static AWS credentials on the host: it gets everything from
# the instance profile.
#   * SSM          - shell access without opening SSH (Session Manager)
#   * ECR pull     - pull the pre-built image when enable_ecr is set
#   * CloudWatch   - metrics/logs agent
#   * S3           - file backups
#   * Secrets Mgmt - read the RDS-managed master password at deploy time
# =============================================================================

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${local.name}-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = { Name = "${local.name}-ec2-role" }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# --- RDS master password (AWS-managed secret) --------------------------------
data "aws_iam_policy_document" "rds_secret" {
  statement {
    sid    = "ReadRdsMasterSecret"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    resources = [aws_db_instance.main.master_user_secret[0].secret_arn]
  }

  # The RDS-managed secret is encrypted with the default `aws/secretsmanager`
  # key; reading it also needs kms:Decrypt, scoped to Secrets Manager.
  statement {
    sid    = "DecryptViaSecretsManager"
    effect = "Allow"

    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "rds_secret" {
  name   = "${local.name}-rds-secret"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.rds_secret.json
}

# --- S3 backups --------------------------------------------------------------
resource "aws_iam_role_policy" "backups" {
  count = var.enable_backup_bucket ? 1 : 0

  name = "${local.name}-backups"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.backups[0].arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
        ]
        Resource = ["${aws_s3_bucket.backups[0].arn}/*"]
      },
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = var.iam_instance_profile_name != "" ? var.iam_instance_profile_name : "${local.name}-ec2"
  role = aws_iam_role.ec2.name

  tags = { Name = "${local.name}-ec2-profile" }
}
