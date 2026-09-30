# =============================================================================
# outputs.tf - foundation
# =============================================================================
# Ephemeral components read these through terraform_remote_state. Treat them
# as the contract: renaming one breaks every component that consumes it.
# =============================================================================

output "vpc_id" {
  description = "Lab VPC."
  value       = aws_vpc.lab.id
}

output "vpc_cidr" {
  description = "CIDR of the lab VPC, for security group rules."
  value       = aws_vpc.lab.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnets, one per availability zone in availability_zones."
  value       = aws_subnet.public[*].id
}

output "availability_zone" {
  description = "The single AZ everything lands in by default."
  value       = var.availability_zones[0]
}

output "ssh_security_group_id" {
  description = "Shared SSH security group."
  value       = aws_security_group.ssh.id
}

output "web_security_group_id" {
  description = "Shared HTTP/HTTPS/Kubernetes-API security group."
  value       = aws_security_group.web.id
}

output "internal_security_group_id" {
  description = "Shared intra-VPC security group."
  value       = aws_security_group.internal.id
}

output "key_pair_name" {
  description = "Imported EC2 key pair, shared by every instance. Empty when ssh_public_key is unset."
  value       = var.ssh_public_key != "" ? aws_key_pair.lab[0].key_name : ""
}

output "instance_profile_name" {
  description = "IAM instance profile for lab nodes: SSM, cert-manager DNS-01, and lab-data S3 access."
  value       = aws_iam_instance_profile.node.name
}

output "node_role_arn" {
  description = "ARN of the lab node IAM role."
  value       = aws_iam_role.node.arn
}

output "route53_zone_id" {
  description = "Hosted zone ID for <subdomain>.<root_domain>. Referenced, never managed by this repo."
  value       = local.zone_id
}

output "persistent_eip_ids" {
  description = "Allocation IDs of persistent Elastic IPs, keyed by the label in persistent_eip_names."
  value       = { for name, eip in aws_eip.persistent : name => eip.allocation_id }
}

output "persistent_eip_addresses" {
  description = "Public addresses of persistent Elastic IPs, keyed by label."
  value       = { for name, eip in aws_eip.persistent : name => eip.public_ip }
}

output "labdata_prefix" {
  description = "S3 prefix inside state_bucket where data that should survive a rebuild is kept."
  value       = "labdata/${var.environment}"
}
