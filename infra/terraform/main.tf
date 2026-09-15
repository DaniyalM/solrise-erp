provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# Canonical Ubuntu 24.04 LTS (Noble) amd64.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  name      = var.name_prefix
  site_name = var.site_name != "" ? var.site_name : "erp.${var.domain}"
  azs       = slice(data.aws_availability_zones.available.names, 0, 2)

  key_name = var.ssh_public_key != "" ? aws_key_pair.generated[0].key_name : var.key_name

  tags = merge(
    {
      Project   = "solrise-erp"
      Role      = "solrise-app" # Ansible discovers the host by this tag.
      ManagedBy = "terraform"
    },
    var.extra_tags,
  )
}
