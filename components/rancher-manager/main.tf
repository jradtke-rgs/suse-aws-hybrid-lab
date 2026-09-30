# =============================================================================
# rancher-manager - single-node RKE2 + Rancher on SL-Micro
# =============================================================================
# The one product v1 exists to demo. Depends on foundation for network, IAM,
# and the key pair; creates no IAM of its own.
# =============================================================================

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project
      Component   = "rancher-manager"
      ManagedBy   = "opentofu"
      Owner       = var.owner
    }
  }
}

data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "state/${var.environment}/foundation/terraform.tfstate"
    region = var.aws_region
  }
}

# Verified live against account 013907871322 (2026-09-30): the naming
# pattern is suse-sle-micro-<major>-<minor>-byos-v<date>-hvm-ssd-<arch>.
# sl_micro_version is pinned (see common-vars.tf) rather than left as
# "suse-sle-micro-6-*" - that looser filter combined with most_recent sorts
# by publication date, so a freshly published 6.0 image can outrank an
# older 6.1 one and silently select the wrong minor version.
data "aws_ami" "sl_micro" {
  most_recent = true
  owners      = ["013907871322"]

  filter {
    name   = "name"
    values = ["suse-sle-micro-${var.sl_micro_version}-byos-v*-hvm-ssd-${var.ami_architecture}"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  le_enabled = var.enable_letsencrypt && var.root_domain != "" && var.letsencrypt_email != ""

  rancher_fqdn  = "${var.hostname_rancher}.${var.subdomain}.${var.root_domain}"
  wildcard_fqdn = "*.${var.subdomain}.${var.root_domain}"

  # One wildcard certificate covers every hostname this lab ever adds - see
  # the note on enable_letsencrypt in common-vars.tf. Every component backs
  # up to, and restores from, the SAME path: whichever one issues first
  # "wins" and the rest just reuse it.
  labdata_tls_prefix = "${data.terraform_remote_state.foundation.outputs.labdata_prefix}/tls/${var.letsencrypt_environment}"

  has_persistent_eip = contains(
    keys(data.terraform_remote_state.foundation.outputs.persistent_eip_addresses),
    "rancher",
  )
  public_ip = local.has_persistent_eip ? (
    data.terraform_remote_state.foundation.outputs.persistent_eip_addresses["rancher"]
  ) : aws_instance.rancher.public_ip
}

# ---------------------------------------------------------------------------
# Presigned restore URLs - see templates/presign-labdata.py for why this
# runs on the operator's machine instead of installing an S3 client on an
# immutable OS. Skipped entirely when Let's Encrypt is off: nothing to
# restore.
# ---------------------------------------------------------------------------
data "external" "tls_backup" {
  count   = local.le_enabled ? 1 : 0
  program = ["python3", "${path.module}/templates/presign-labdata.py"]

  query = {
    bucket     = var.labdata_bucket
    prefix     = local.labdata_tls_prefix
    expires_in = "3600"
  }
}

# ---------------------------------------------------------------------------
# Security group for what is specific to this node. SSH/HTTP/HTTPS/K8s-API
# already come from foundation's shared `web` and `ssh` groups.
# ---------------------------------------------------------------------------
resource "aws_security_group" "rancher_extra" {
  name_prefix = "${var.environment}-rancher-"
  description = "RKE2 supervisor API - for downstream nodes/clusters this Rancher will one day provision"
  vpc_id      = data.terraform_remote_state.foundation.outputs.vpc_id

  ingress {
    description = "RKE2 supervisor API"
    from_port   = 9345
    to_port     = 9345
    protocol    = "tcp"
    cidr_blocks = var.allowed_web_cidr_blocks
  }

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.environment}-rancher-extra" }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# The instance
# ---------------------------------------------------------------------------
resource "aws_instance" "rancher" {
  ami                  = var.ami_id != "" ? var.ami_id : data.aws_ami.sl_micro.id
  instance_type        = var.rancher_instance_type
  subnet_id            = data.terraform_remote_state.foundation.outputs.public_subnet_ids[0]
  key_name             = data.terraform_remote_state.foundation.outputs.key_pair_name != "" ? data.terraform_remote_state.foundation.outputs.key_pair_name : null
  iam_instance_profile = data.terraform_remote_state.foundation.outputs.instance_profile_name

  vpc_security_group_ids = [
    aws_security_group.rancher_extra.id,
    data.terraform_remote_state.foundation.outputs.web_security_group_id,
    data.terraform_remote_state.foundation.outputs.ssh_security_group_id,
    data.terraform_remote_state.foundation.outputs.internal_security_group_id,
  ]

  root_block_device {
    volume_size           = var.rancher_root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user-data.sh", {
    environment    = var.environment
    hostname       = local.rancher_fqdn
    hostname_short = var.hostname_rancher
    wildcard_fqdn  = local.wildcard_fqdn

    rke2_version           = var.rke2_version
    rancher_version        = var.rancher_version
    cert_manager_version   = var.cert_manager_version
    rancher_chart_override = var.rancher_chart_override
    rancher_image_override = var.rancher_image_override

    private_registry          = var.private_registry
    private_registry_username = var.private_registry_username
    private_registry_password = var.private_registry_password

    enable_letsencrypt      = local.le_enabled
    letsencrypt_email       = var.letsencrypt_email
    letsencrypt_environment = var.letsencrypt_environment
    aws_region              = var.aws_region
    route53_zone_id         = data.terraform_remote_state.foundation.outputs.route53_zone_id

    tls_restore_cert_url = local.le_enabled ? data.external.tls_backup[0].result.cert_url : ""
    tls_restore_acme_url = local.le_enabled ? data.external.tls_backup[0].result.acme_url : ""

    letsencrypt_clusterissuer = local.le_enabled ? templatefile("${path.module}/letsencrypt-clusterissuer.yaml.tpl", {
      letsencrypt_email = var.letsencrypt_email
      aws_region        = var.aws_region
      route53_zone_id   = data.terraform_remote_state.foundation.outputs.route53_zone_id
    }) : ""
    letsencrypt_certificate = local.le_enabled ? templatefile("${path.module}/letsencrypt-certificate.yaml.tpl", {
      wildcard_fqdn           = local.wildcard_fqdn
      letsencrypt_environment = var.letsencrypt_environment
    }) : ""
  })

  tags = { Name = "${var.environment}-rancher-manager" }

  lifecycle {
    # A new SL-Micro publication should never silently replace a running
    # node on an otherwise-idempotent `democtl build` - see sl_micro_version
    # in common-vars.tf. Rebuilding onto a newer image is a deliberate act:
    # `democtl destroy --only rancher-manager && democtl build`.
    ignore_changes = [ami]
  }
}

# ---------------------------------------------------------------------------
# Public address
# ---------------------------------------------------------------------------
# Associates foundation's persistent EIP when "rancher" is in
# persistent_eip_names; otherwise uses the instance's own automatic public
# IP. See the cost note on persistent_eip_names in components/foundation -
# there is no cost difference between the two while the lab is running.
resource "aws_eip_association" "rancher" {
  count         = local.has_persistent_eip ? 1 : 0
  instance_id   = aws_instance.rancher.id
  allocation_id = data.terraform_remote_state.foundation.outputs.persistent_eip_ids["rancher"]
}

# Short TTL: without a persisted EIP, the address can change on every
# rebuild, and a long TTL would leave stale caches pointed at a dead IP.
resource "aws_route53_record" "rancher" {
  count   = var.root_domain != "" ? 1 : 0
  zone_id = data.terraform_remote_state.foundation.outputs.route53_zone_id
  name    = local.rancher_fqdn
  type    = "A"
  ttl     = 60
  records = [local.public_ip]
}
