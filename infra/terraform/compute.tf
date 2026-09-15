# =============================================================================
# Application host: one Ubuntu EC2 instance with a static Elastic IP.
#
# Terraform stops at "reachable over SSH with podman not yet installed" - the
# real configuration is Ansible's job (infra/ansible/roles/host).
# =============================================================================

resource "aws_key_pair" "generated" {
  count = var.ssh_public_key != "" ? 1 : 0

  key_name   = "${local.name}-key"
  public_key = var.ssh_public_key

  tags = { Name = "${local.name}-key" }
}

resource "aws_instance" "main" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = local.key_name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  # IMDSv2 only.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # Minimal bootstrap only: the AMI ships no Ansible interpreter guarantee, so
  # install python3 and leave the rest to the Ansible `host` role.
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y python3-minimal
  EOT

  tags = { Name = "${local.name}-app" }

  lifecycle {
    ignore_changes = [ami] # keep the instance on its AMI until deliberately replaced
  }
}

resource "aws_eip" "main" {
  domain = "vpc"

  tags = { Name = "${local.name}-eip" }
}

resource "aws_eip_association" "main" {
  instance_id   = aws_instance.main.id
  allocation_id = aws_eip.main.id
}
