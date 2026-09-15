# =============================================================================
# S3 bucket for file backups (attachments, private files). The database has its
# own RDS snapshots; this is the off-box half of the backup story.
# =============================================================================

resource "aws_s3_bucket" "backups" {
  count = var.enable_backup_bucket ? 1 : 0

  bucket        = var.backup_bucket_name != "" ? var.backup_bucket_name : "${local.name}-backups-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  tags = { Name = "${local.name}-backups" }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  count = var.enable_backup_bucket ? 1 : 0

  bucket = aws_s3_bucket.backups[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "backups" {
  count = var.enable_backup_bucket ? 1 : 0

  bucket = aws_s3_bucket.backups[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  count = var.enable_backup_bucket ? 1 : 0

  bucket = aws_s3_bucket.backups[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  count = var.enable_backup_bucket ? 1 : 0

  bucket = aws_s3_bucket.backups[0].id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {}

    expiration {
      days = var.backup_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# =============================================================================
# ECR (optional): build the image once on a workstation/CI and let EC2 pull it,
# instead of compiling erpnext + hrms on the production host.
# =============================================================================

resource "aws_ecr_repository" "app" {
  count = var.enable_ecr ? 1 : 0

  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${local.name}-ecr" }
}

resource "aws_ecr_lifecycle_policy" "app" {
  count = var.enable_ecr ? 1 : 0

  repository = aws_ecr_repository.app[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}
