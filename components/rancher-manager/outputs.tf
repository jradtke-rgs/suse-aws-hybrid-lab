# =============================================================================
# outputs.tf - rancher-manager
# =============================================================================

output "rancher_url" {
  description = "Where to reach Rancher. May take several minutes to answer after `democtl build` returns - see hooks/post-apply.sh, which waits for it."
  value       = "https://${local.rancher_fqdn}"
}

output "rancher_hostname" {
  description = "FQDN used for the instance's TLS SAN and Route53 record."
  value       = local.rancher_fqdn
}

output "hostname" {
  description = "Alias of rancher_hostname - the name every component's outputs.tf uses, for hooks that read outputs generically."
  value       = local.rancher_fqdn
}

output "instance_id" {
  value = aws_instance.rancher.id
}

output "public_ip" {
  value = local.public_ip
}

output "private_ip" {
  value = aws_instance.rancher.private_ip
}

output "security_group_id" {
  description = "This component's own security group (RKE2 supervisor port). The shared ssh/web/internal groups live in foundation's outputs."
  value       = aws_security_group.rancher_extra.id
}

output "iam_role_arn" {
  description = "ARN of the shared node role this instance runs as (from foundation - this component creates no IAM of its own)."
  value       = data.terraform_remote_state.foundation.outputs.node_role_arn
}

output "ssh_command" {
  description = "Consumed by `democtl ssh rancher-manager` and by the backup/restore hooks."
  value       = "ssh -i ${var.ssh_private_key_path} -o StrictHostKeyChecking=accept-new ec2-user@${local.public_ip}"
}

output "labdata_tls_prefix" {
  description = "S3 key prefix this build's TLS certificate and ACME account key are backed up to/restored from. Namespaced by letsencrypt_environment - see the note in main.tf's locals."
  value       = local.labdata_tls_prefix
}

output "bootstrap_password" {
  description = "user-data.sh sets this explicitly via --set bootstrapPassword=admin at install time (matching the reference implementation) rather than Rancher's own random default, so there is no secret to fetch - log in with this and change it immediately. Fine for an ephemeral demo lab; do not do this for anything that stays up."
  value       = "admin"
}
