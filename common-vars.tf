# =============================================================================
# common-vars.tf - GLOBAL variables only
# =============================================================================
# Every component symlinks this file into its own directory, so anything
# declared here is available to every component. Edit the copy at the repo
# root, never the symlink.
#
# The rule for what belongs here: a variable is global if MORE THAN ONE
# component needs it, or if it describes the lab as a whole (region, DNS,
# credentials). Anything a single component owns - its instance type, its
# volume size, its hostname, its enable_<name> flag - belongs in THAT
# component's variables.tf instead. See components/_template/README.md.
#
# democtl does not pass this whole file to every component. It generates a
# per-component .auto.tfvars holding only the keys that component actually
# declares, which is why OpenTofu never prints "undeclared variable"
# warnings here. See Scripts/lib/tfvars.sh.
# =============================================================================

# -----------------------------------------------------------------------------
# Identity - these three name and tag everything
# -----------------------------------------------------------------------------
variable "environment" {
  description = "Lab name. Used as the resource name prefix, the Environment tag (which `democtl orphans` keys off), the DNS subdomain, and the OpenTofu state key prefix."
  type        = string
  default     = "suse-aws-hybrid-lab"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$", var.environment))
    error_message = "The environment must be lowercase alphanumeric with hyphens (it becomes part of S3 bucket and DNS names)."
  }
}

variable "project" {
  description = "Project tag applied to every resource. Distinct from environment: several labs can share a project."
  type        = string
  default     = "suse-aws-hybrid-lab"
}

variable "owner" {
  description = "Owner tag applied to every resource."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# AWS placement
# -----------------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region. Single region by design - this is a demo lab, not a resilient deployment."
  type        = string
  default     = "us-east-2"
}

variable "availability_zones" {
  description = "AZs to place subnets in. One entry is the intended default (no cross-AZ data charges). A second entry is only needed if you later add a component that requires two AZs, such as EKS."
  type        = list(string)
  default     = ["us-east-2a"]
}

variable "vpc_cidr" {
  description = <<-EOT
    CIDR block for the lab VPC. Defaults to 172.16.0.0/16 - deliberately
    OUTSIDE 10.0.0.0/8, because this repo is a HYBRID lab: if you route or
    peer it to an on-prem network that also uses RFC1918 space (a homelab,
    say), any overlap breaks routing on whichever side has the smaller
    prefix. 172.16.0.0/12 is large enough that a single lab's /16 out of it
    is unlikely to collide with home-router defaults (192.168.0.0/16) or a
    homelab's own 10.0.0.0/8 usage - but if 172.16.0.0/16 overlaps
    something you already run, change this before the first
    `democtl foundation up`. AWS cannot change a VPC's CIDR in place: fixing
    it after the fact means tearing foundation down and rebuilding it.
  EOT
  type        = string
  default     = "172.16.0.0/16"
}

variable "enable_nat_gateway" {
  description = "Deploy a NAT Gateway. Off by design: a NAT GW costs more per month than everything else in this lab combined, and every instance here lives in a public subnet. Kept as a flag so a private-subnet component can be added later."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Remote state - democtl fills these in; you do not set them in terraform.tfvars
# -----------------------------------------------------------------------------
# foundation creates the state bucket, then migrates its own state into it
# (`democtl foundation up` does this automatically). Every other component
# reads a dependency's outputs via terraform_remote_state against this
# bucket. democtl passes the value on the command line, so no bucket name is
# ever hardcoded in a .tf file.
variable "state_bucket" {
  description = "S3 bucket holding OpenTofu state. Injected by democtl - leave unset in terraform.tfvars."
  type        = string
  default     = ""
}

variable "labdata_bucket" {
  description = "S3 bucket holding lab data that should survive a rebuild (TLS certificate backups, Rancher backups). Injected by democtl - leave unset in terraform.tfvars."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Access control
# -----------------------------------------------------------------------------
variable "allowed_ssh_cidr_blocks" {
  description = "CIDRs allowed to reach port 22. Narrow this to your own address; the default is open so a first run works from anywhere."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_web_cidr_blocks" {
  description = "CIDRs allowed to reach HTTP/HTTPS and the Kubernetes API."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_public_key" {
  description = "SSH public key imported into AWS once by foundation and reused by every instance."
  type        = string
  default     = ""

  validation {
    condition = (
      var.ssh_public_key == "" ||
      can(regex("^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ", var.ssh_public_key))
    )
    error_message = "The ssh_public_key must be a valid SSH public key starting with ssh-rsa, ssh-ed25519, or ecdsa-sha2-*."
  }
}

variable "ssh_private_key_path" {
  description = "Path to the matching private key on YOUR workstation. Only used to build the ssh_command outputs and by `democtl ssh` - never uploaded anywhere."
  type        = string
  default     = "~/.ssh/suse-aws-hybrid-lab.pem"
}

# -----------------------------------------------------------------------------
# DNS (Route53) - the hosted zone must already exist; this repo never creates
# or destroys it
# -----------------------------------------------------------------------------
variable "root_domain" {
  description = "Registered domain that holds the hosted zone (e.g. kubernerdes.com)."
  type        = string
  default     = ""
}

variable "subdomain" {
  description = "Zone this lab owns, relative to root_domain. Every hostname becomes <hostname>.<subdomain>.<root_domain>. Defaults to matching the environment name."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Hosted zone ID for <subdomain>.<root_domain>. Leave empty to look it up by name."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# TLS - Let's Encrypt via cert-manager, DNS-01 against Route53
# -----------------------------------------------------------------------------
# One WILDCARD certificate (*.<subdomain>.<root_domain>) is issued for the
# whole lab rather than one certificate per hostname. Two reasons:
#   1. Let's Encrypt's duplicate-certificate limit is 5 per week per exact
#      set of identifiers. Every component sharing one wildcard means one
#      budget for the entire lab, not one per product.
#   2. Every component added later gets TLS for free - it consumes the
#      existing wildcard Secret instead of solving issuance again.
# DNS-01 is required for a wildcard anyway, and cert-manager already uses it.
variable "enable_letsencrypt" {
  description = "Issue a real Let's Encrypt wildcard certificate via cert-manager. Off means self-signed and a browser warning."
  type        = bool
  default     = true
}

variable "letsencrypt_email" {
  description = "Contact address for the ACME account (expiry notices)."
  type        = string
  default     = ""

  validation {
    condition = (
      var.letsencrypt_email == "" ||
      can(regex("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.letsencrypt_email))
    )
    error_message = "The letsencrypt_email must be a valid email address when provided."
  }
}

variable "letsencrypt_environment" {
  description = "'staging' issues untrusted certs with generous rate limits - correct while iterating. 'production' issues real certs and is limited to 5 duplicates per week. Keep this on staging until the certificate backup/restore path (see rancher-manager/README.md) has been proven on your own account."
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["staging", "production"], var.letsencrypt_environment)
    error_message = "The letsencrypt_environment must be either 'staging' or 'production'."
  }
}

# -----------------------------------------------------------------------------
# Carbide Secured Registry
# -----------------------------------------------------------------------------
# registry.ranchercarbide.dev is the acquisition point for RGS-hardened
# images, and is itself Harbor-backed. Note that Harbor answers 401/403
# identically for "wrong credentials" and "that repository or tag does not
# exist" - before concluding you have an entitlement problem, check
# /v2/_catalog and /v2/<repo>/tags/list directly.
variable "carbide_registry" {
  description = "Carbide Secured Registry hostname."
  type        = string
  default     = "registry.ranchercarbide.dev"
}

variable "carbide_username" {
  description = "Carbide Portal registry username."
  type        = string
  default     = ""
  sensitive   = true
}

variable "carbide_password" {
  description = "Carbide Portal registry password or token."
  type        = string
  default     = ""
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Base image and Kubernetes version
# -----------------------------------------------------------------------------
# These are global because every node-bearing component uses the same base
# image and the same RKE2 version, and because keeping them in one place is
# what makes the version-coupling check in `democtl versions` possible.
variable "ami_id" {
  description = "Explicit AMI ID. Overrides the SL-Micro lookup below. Useful for pinning a known-good image."
  type        = string
  default     = ""
}

variable "sl_micro_version" {
  description = "SL-Micro minor version to select, as it appears in the AMI name (e.g. '6-1'). Pinned deliberately: the looser 'suse-sle-micro-6-*' filter combined with most_recent sorts by publication date, so a freshly published 6.0 image wins over an older 6.1 one and you silently get the older minor version."
  type        = string
  default     = "6-1"
}

variable "ami_architecture" {
  description = "CPU architecture. arm64 SL-Micro AMIs exist and Graviton instances are roughly 20 percent cheaper, but Carbide's arm64 image coverage is unverified - leave this on x86_64 unless you are testing that path."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.ami_architecture)
    error_message = "The ami_architecture must be x86_64 or arm64."
  }
}

# Pin this. Do not leave it empty.
#
# Two separate failures follow from an unpinned "latest stable" RKE2:
#   1. Rancher's Helm chart pins a Kubernetes ceiling (2.15.2 requires
#      kubeVersion < 1.37.0-0). RKE2 v1.37.0 is already released, so latest
#      stable is now ABOVE that ceiling and `helm install rancher` fails.
#   2. The installer resolves "stable" through
#      https://update.rke2.io/v1-release/channels, which was returning 404
#      when this repo was written - an unpinned install cannot even
#      determine a version.
# `democtl versions` checks the current pinning against the live Rancher
# chart index and cert-manager's support window.
variable "rke2_version" {
  description = "RKE2 version to install (e.g. v1.36.4+rke2r1). Must satisfy the Rancher chart's kubeVersion ceiling - see the note above this variable."
  type        = string
  default     = "v1.36.4+rke2r1"
}

variable "cert_manager_version" {
  description = "cert-manager version. Supports a rolling window of Kubernetes releases, so it is coupled to rke2_version - see https://cert-manager.io/docs/releases/."
  type        = string
  default     = "1.21.2"
}
