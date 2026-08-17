provider "aws" {
  region  = var.region
  profile = var.aws_profile == "" ? null : var.aws_profile

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

# Confirms which account Terraform actually authenticated against — check this output before
# ever running `apply`, since credential resolution (profile, env vars, SSO) happens outside
# this repo entirely and it's easy to have the wrong one active without noticing.
data "aws_caller_identity" "current" {}
