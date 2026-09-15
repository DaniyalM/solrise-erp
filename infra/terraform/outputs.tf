# =============================================================================
# Outputs. The two local_file resources are the Terraform -> Ansible handoff:
# they render a working inventory and the AWS facts the deploy role needs.
# =============================================================================

output "app_public_ip" {
  description = "Elastic IP of the application host."
  value       = aws_eip.main.public_ip
}

output "ssh_command" {
  description = "SSH command for the instance (also reachable via SSM)."
  value       = "ssh ubuntu@${aws_eip.main.public_ip}"
}

output "ssm_start_session_command" {
  description = "Shell access without SSH, through Session Manager."
  value       = "aws ssm start-session --target ${aws_instance.main.id} --region ${var.aws_region}"
}

output "rds_endpoint" {
  description = "RDS host:port for the application."
  value       = "${aws_db_instance.main.address}:${aws_db_instance.main.port}"
}

output "rds_address" {
  description = "RDS hostname only (goes into DB_HOST)."
  value       = aws_db_instance.main.address
}

output "rds_port" {
  description = "RDS port."
  value       = aws_db_instance.main.port
}

output "db_root_username" {
  description = "RDS master username (DB_ROOT_USERNAME)."
  value       = aws_db_instance.main.username
}

output "db_secret_arn" {
  description = "Secrets Manager ARN holding the RDS master credentials."
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "site_name" {
  description = "Frappe site name."
  value       = local.site_name
}

output "backup_bucket" {
  description = "S3 bucket for file backups (empty when disabled)."
  value       = var.enable_backup_bucket ? aws_s3_bucket.backups[0].bucket : ""
}

output "ecr_repository_url" {
  description = "ECR repository URL (empty when disabled). Paste into GitHub as the ECR_REPOSITORY_URL variable and as CUSTOM_IMAGE on the host."
  value       = var.enable_ecr ? aws_ecr_repository.app[0].repository_url : ""
}

output "github_actions_role_arn" {
  description = "Role for GitHub Actions to assume via OIDC. Set as the AWS_ROLE_ARN repository variable."
  value       = local.enable_github_oidc ? aws_iam_role.github_actions[0].arn : ""
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider (created or reused)."
  value       = local.github_oidc_provider_arn
}

output "ansible_inventory_file" {
  description = "Path to the generated Ansible inventory."
  value       = local_file.ansible_inventory.filename
}

output "ansible_group_vars_file" {
  description = "Path to the generated Ansible group vars."
  value       = local_file.ansible_group_vars.filename
}

# ---------------------------------------------------------------- TF -> Ansible

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory/hosts.ini"
  content = templatefile("${path.module}/templates/inventory.ini.tftpl", {
    host_name    = local.name
    public_ip    = aws_eip.main.public_ip
    ssh_user     = "ubuntu"
    ssh_key_line = var.ssh_private_key_path != "" ? " ansible_ssh_private_key_file=${var.ssh_private_key_path}" : ""
  })
}

resource "local_file" "ansible_group_vars" {
  filename = "${path.module}/../ansible/group_vars/all/terraform.yml"
  content = templatefile("${path.module}/templates/group_vars.yml.tftpl", {
    aws_region         = var.aws_region
    public_ip          = aws_eip.main.public_ip
    domain             = var.domain
    site_name          = local.site_name
    letsencrypt_email  = var.letsencrypt_email
    rds_host           = aws_db_instance.main.address
    rds_port           = aws_db_instance.main.port
    db_username        = aws_db_instance.main.username
    db_secret_arn      = aws_db_instance.main.master_user_secret[0].secret_arn
    backup_bucket      = var.enable_backup_bucket ? aws_s3_bucket.backups[0].bucket : ""
    ecr_repository_url = var.enable_ecr ? aws_ecr_repository.app[0].repository_url : ""
  })
}
