# =============================================================================
# variables.tf - settings this component owns
# =============================================================================
# Anything only this component uses belongs here, not in common-vars.tf:
# its instance type, its volume size, its hostname, its chart version, its
# enable flag. Keeping them local is what lets a new component be added
# without touching a shared file.
#
# democtl generates democtl.auto.tfvars holding exactly the variables
# declared here and in common-vars.tf, filtered out of the root
# terraform.tfvars. That is why OpenTofu never complains about the forty
# other settings in that file.
# =============================================================================

variable "enable___COMPONENT_UNDERSCORE__" {
  description = "Deploy this component. Matches ENABLE_VAR in component.conf."
  type        = bool
  default     = false
}

variable "hostname___COMPONENT_UNDERSCORE__" {
  description = "Hostname for this component, becoming <hostname>.<subdomain>.<root_domain>."
  type        = string
  default     = "__COMPONENT_NAME__"
}

variable "__COMPONENT_UNDERSCORE___instance_type" {
  description = "EC2 instance type. Pick the smallest that actually works and say why in the README."
  type        = string
  default     = "t3.medium"
}
