terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Remote state is strongly recommended for anything beyond a single operator.
# Uncomment and fill in, then `terraform init -migrate-state`.
#
# terraform {
#   backend "s3" {
#     bucket         = "my-tfstate-bucket"
#     key            = "solrise/terraform.tfstate"
#     region         = "us-east-1"
#     dynamodb_table = "terraform-locks"
#     encrypt        = true
#   }
# }
