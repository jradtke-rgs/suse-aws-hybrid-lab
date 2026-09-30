# =============================================================================
# variables.tf - rancher-manager
# =============================================================================
# Settings only this component owns. Everything shared (rke2_version,
# rancher hostname vs. subdomain/root_domain, the optional private registry,
# Let's Encrypt) lives in common-vars.tf instead.
# =============================================================================

variable "hostname_rancher" {
  description = "Hostname for Rancher, becoming <hostname>.<subdomain>.<root_domain>."
  type        = string
  default     = "rancher"
}

variable "rancher_instance_type" {
  description = <<-EOT
    EC2 instance type for the single-node RKE2 + Rancher server.

    t3.large (2 vCPU / 8GB) is the smallest type that runs RKE2, Rancher,
    cert-manager and the RKE2-bundled containerd together without hitting
    memory pressure on this repo's predecessor. t3.medium (4GB) was tried
    there and swapped under load once Rancher's own pods were scheduled
    alongside RKE2's control plane components - not worth chasing for a
    demo where reliability during the walkthrough matters more than a
    fraction of a cent per hour.
  EOT
  type        = string
  default     = "t3.large"
}

variable "rancher_root_volume_size" {
  description = <<-EOT
    Root volume size in GB, gp3. Billed even while the instance is stopped,
    so this is sized to what the stack actually uses rather than copied from
    a bigger default: RKE2 + its bundled containerd + Helm + cert-manager +
    Rancher + whatever images get pulled for all of them lands around
    15-20GB in practice. 50GB leaves real headroom (image churn during a
    demo, RKE2/containerd garbage that collects between rebuilds) without
    paying for space that will sit empty.
  EOT
  type        = number
  default     = 50
}

variable "rancher_version" {
  description = "Rancher Helm chart version. Coupled to rke2_version via the chart's kubeVersion ceiling - see the note on rke2_version in common-vars.tf, and run `democtl versions` before changing either."
  type        = string
  default     = "2.15.2"
}

variable "rancher_chart_override" {
  description = "OCI reference for a Rancher Helm chart to install from instead of the public rancher-stable chart - for a private/hardened chart source, if you have one. Empty (the default) installs the public chart with images sourced via registries.yaml against private_registry, if set."
  type        = string
  default     = ""
}

variable "rancher_image_override" {
  description = "Image path for Rancher to override the chart's default (e.g. your-registry.example.com/rancher/rancher). Empty uses the chart's own default image."
  type        = string
  default     = ""
}
