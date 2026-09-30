# =============================================================================
# outputs.tf - what other components and democtl can read
# =============================================================================
# Two outputs have meaning to democtl itself:
#   ssh_command                 `democtl ssh <component>` runs this verbatim
#   <component>_url             `democtl urls` falls back to it when there
#                               is no hooks/urls.sh
# Everything else is for other components, via component_output.
# =============================================================================

output "__COMPONENT_UNDERSCORE___url" {
  description = "Where to reach this component."
  value       = "https://${local.fqdn}"
}

output "hostname" {
  description = "Fully qualified name for this component."
  value       = local.fqdn
}
