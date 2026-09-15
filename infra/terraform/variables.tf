# =============================================================================
# Inputs. Everything has a sane default except the domain, admin email and the
# SSH key used to reach the instance on first boot.
# =============================================================================

# --- general -----------------------------------------------------------------
variable "aws_region" {
  description = "AWS region. Keep the app and RDS in the same region."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for every AWS resource name and the Name tag."
  type        = string
  default     = "solrise"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,24}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric/dashes, 2-25 chars."
  }
}

variable "extra_tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}

# --- application -------------------------------------------------------------
variable "domain" {
  description = "Public FQDN the app is served on, e.g. erp.example.com."
  type        = string
}

variable "site_name" {
  description = "Frappe site name. Defaults to erp.<domain>."
  type        = string
  default     = ""
}

variable "letsencrypt_email" {
  description = "Contact email for Let's Encrypt (ACME) registration."
  type        = string
}

# --- access ------------------------------------------------------------------
variable "ssh_public_key" {
  description = "Public key material for a key pair created by Terraform. Leave empty to use `key_name` instead."
  type        = string
  default     = ""
}

variable "key_name" {
  description = "Name of an existing EC2 key pair to attach (used when ssh_public_key is empty)."
  type        = string
  default     = ""
}

variable "ssh_private_key_path" {
  description = "Path to the private key, written into the generated Ansible inventory."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "ssh_cidr_blocks" {
  description = "CIDRs allowed to reach SSH. Restrict to your office/VPN egress."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# --- network -----------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR for the dedicated VPC."
  type        = string
  default     = "10.42.0.0/16"
}

# --- compute -----------------------------------------------------------------
variable "instance_type" {
  description = "EC2 instance type. The image build needs >= 8 GB RAM (or swap)."
  type        = string
  default     = "t3.large"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB. Holds podman volumes (sites, files, redis queue)."
  type        = number
  default     = 80
}

variable "iam_instance_profile_name" {
  description = "Override the generated IAM instance profile name (rarely needed)."
  type        = string
  default     = ""
}

# --- RDS MariaDB -------------------------------------------------------------
variable "db_engine_version" {
  description = "RDS MariaDB engine version. Must match db_parameter_group_family."
  type        = string
  default     = "11.4"
}

variable "db_parameter_group_family" {
  description = "RDS parameter group family, e.g. mariadb11.4 or mariadb10.11."
  type        = string
  default     = "mariadb11.4"
}

variable "db_instance_class" {
  description = "RDS instance class. Size for Frappe's many small connections."
  type        = string
  default     = "db.t4g.medium"
}

variable "db_allocated_storage" {
  description = "Initial RDS storage in GiB."
  type        = number
  default     = 50
}

variable "db_max_allocated_storage" {
  description = "Upper bound for RDS storage autoscaling in GiB (0 disables)."
  type        = number
  default     = 200
}

variable "db_name" {
  description = "Optional initial database name. Leave null - Frappe creates its own."
  type        = string
  default     = null
}

variable "db_username" {
  description = "RDS master username. Must not be a reserved name (root, rdsadmin)."
  type        = string
  default     = "solrise_admin"
}

variable "db_port" {
  description = "MariaDB port."
  type        = number
  default     = 3306
}

variable "db_multi_az" {
  description = "Run RDS Multi-AZ (standby in a second AZ). Recommended for production."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "Automated snapshot retention / PITR window in days (0 disables)."
  type        = number
  default     = 14
}

variable "db_apply_immediately" {
  description = "Apply RDS modifications immediately instead of in the maintenance window."
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "Block accidental RDS deletion. Set false for throwaway stacks."
  type        = bool
  default     = true
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Set true only for disposable stacks."
  type        = bool
  default     = false
}

variable "db_performance_insights" {
  description = "Enable RDS Performance Insights."
  type        = bool
  default     = false
}

# --- DNS ---------------------------------------------------------------------
variable "route53_zone_id" {
  description = "Route 53 hosted zone ID for the A record. Empty = do not manage DNS."
  type        = string
  default     = ""
}

# --- artifacts ---------------------------------------------------------------
variable "enable_ecr" {
  description = "Create the ECR repository. ECR is the primary image source: GitHub Actions builds and pushes, EC2 pulls."
  type        = bool
  default     = true
}

variable "ecr_repository_name" {
  description = "ECR repository name when enable_ecr is true."
  type        = string
  default     = "solrise/erpnext"
}

# --- GitHub Actions (OIDC image build) --------------------------------------
variable "github_repository" {
  description = "GitHub repo allowed to push images via OIDC, as owner/name. Empty disables the CI role."
  type        = string
  default     = ""
}

variable "github_oidc_branch" {
  description = "The only ref allowed to assume the CI role, e.g. refs/heads/main."
  type        = string
  default     = "refs/heads/main"
}

variable "create_github_oidc_provider" {
  description = "Create the account-level GitHub OIDC provider. Set false if the account already has one."
  type        = bool
  default     = true
}

variable "github_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider, used when create_github_oidc_provider is false."
  type        = string
  default     = ""
}

variable "enable_backup_bucket" {
  description = "Create an S3 bucket for file backups and grant the instance write access."
  type        = bool
  default     = true
}

variable "backup_bucket_name" {
  description = "Explicit S3 bucket name. Empty = <name_prefix>-backups-<account_id>."
  type        = string
  default     = ""
}

variable "backup_retention_days" {
  description = "S3 lifecycle expiry for backups in days."
  type        = number
  default     = 30
}
