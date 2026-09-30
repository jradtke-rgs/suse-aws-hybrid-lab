# =============================================================================
# variables.tf - foundation
# =============================================================================
# Almost everything foundation needs is global (region, CIDR, SSH key, DNS).
# What is left is the handful of choices only this component makes.
# =============================================================================

variable "persistent_eip_names" {
  description = <<-EOT
    Labels to allocate a persistent Elastic IP for, e.g. ["rancher"]. An
    ephemeral component associates one instead of taking a new public IP, so
    its DNS name points at an address that never changes.

    Understand the cost before turning this on. AWS bills EVERY public IPv4
    address at about $3.65/month, including the one an instance gets
    automatically - so a persistent EIP costs nothing extra while the lab is
    running. What it costs is $3.65/month per address while the lab is torn
    down and the address sits idle. Empty by default: the A record is simply
    updated on each build instead.
  EOT
  type        = list(string)
  default     = []
}
