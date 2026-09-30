# =============================================================================
# main.tf - __COMPONENT_NAME__
# =============================================================================
# A working skeleton. It reads foundation's outputs and creates nothing, so
# it is safe to `tofu plan` before you have written anything real.
# =============================================================================

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Deliberately empty. democtl supplies bucket, key, region, encryption and
  # locking on the `tofu init` command line, so no bucket name is ever
  # written into a .tf file and one checkout works against any environment.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  # Every resource gets these. `democtl orphans` finds strays by the
  # Environment tag, so a resource without them is a resource no cleanup
  # command can see.
  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project
      Component   = "__COMPONENT_NAME__"
      ManagedBy   = "opentofu"
      Owner       = var.owner
    }
  }
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
# Read another component's outputs through terraform_remote_state, and only
# for components listed in DEPENDS_ON. Never reach into a sibling's state
# file by path - where state lives is democtl's business and has already
# changed once.
data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "state/${var.environment}/foundation/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  fqdn = "${var.hostname___COMPONENT_UNDERSCORE__}.${var.subdomain}.${var.root_domain}"

  # Available from foundation - see components/foundation/outputs.tf:
  #   vpc_id, public_subnet_ids, availability_zone
  #   ssh_security_group_id, internal_security_group_id, web_security_group_id
  #   key_pair_name, instance_profile_name
  #   route53_zone_id, labdata_bucket
  subnet_id = data.terraform_remote_state.foundation.outputs.public_subnet_ids[0]
}

# ---------------------------------------------------------------------------
# Your resources go here.
# ---------------------------------------------------------------------------
# Start from components/rancher-manager/main.tf - it shows the full pattern
# for an instance: AMI lookup, security group, user-data from a template,
# Route53 record, and the lifecycle block that keeps a new AMI publication
# from silently replacing a running node.
