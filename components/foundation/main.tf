# =============================================================================
# foundation - the persistent tier
# =============================================================================
# Everything here is free or costs pennies, is created once, and survives
# `democtl destroy`. The split is the point: tearing the lab down should
# leave nothing billing by the hour, while keeping the pieces whose
# recreation is slow, flaky, or drift-prone.
#
#   VPC / subnet / IGW / route table   free, and recreating them each time
#                                      adds minutes of churn for no saving
#   Security groups                    free
#   EC2 key pair                       free, and re-importing it after an
#                                      interrupted destroy is exactly how
#                                      the "key pair already exists" stray
#                                      happens
#   IAM role + instance profile        free, and stable ARNs mean no waiting
#                                      on IAM eventual consistency at the
#                                      start of every rebuild
#
# The S3 bucket is NOT here. It is created and configured by the AWS CLI in
# `democtl foundation up`, before any OpenTofu runs, for two reasons: this
# component's own state lives in it (so managing it here would mean managing
# the thing holding its own state), and a `destroy` typo should never be
# able to delete state history. The Route53 zone is excluded for the same
# reason - both are referenced, never created or destroyed.
# =============================================================================

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
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
      Component   = "foundation"
      ManagedBy   = "opentofu"
      Owner       = var.owner
    }
  }
}

data "aws_route53_zone" "lab" {
  count        = var.root_domain != "" ? 1 : 0
  name         = "${var.subdomain}.${var.root_domain}"
  private_zone = false
}

locals {
  name = var.environment

  # One subnet per AZ listed. One AZ is the intended configuration; a second
  # entry is what a future EKS component would need, since EKS insists on
  # two. /20 subnets out of a /16 leaves room for 16 of them.
  az_count = length(var.availability_zones)

  zone_id = var.route53_zone_id != "" ? trimprefix(var.route53_zone_id, "/hostedzone/") : (
    var.root_domain != "" ? data.aws_route53_zone.lab[0].zone_id : ""
  )
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = { Name = "${local.name}-igw" }
}

# Public subnets only. Every instance in this lab needs to pull images from
# the internet, and a NAT Gateway to give private subnets that access would
# cost more per month than the rest of the lab combined.
resource "aws_subnet" "public" {
  count                   = local.az_count
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name}-public-${var.availability_zones[count.index]}"
    Type = "public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------
# Three shared groups rather than one per component. A component attaches
# the ones it needs and adds its own group for anything specific to it (RKE2
# supervisor ports, say). create_before_destroy everywhere, because a group
# still attached to a running instance cannot be deleted.
# ---------------------------------------------------------------------------
resource "aws_security_group" "ssh" {
  name_prefix = "${local.name}-ssh-"
  description = "SSH from allowed CIDRs"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidr_blocks
  }

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-ssh" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "web" {
  name_prefix = "${local.name}-web-"
  description = "HTTP, HTTPS and the Kubernetes API from allowed CIDRs"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "HTTP (redirects to HTTPS, and serves ACME HTTP-01 if ever needed)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_web_cidr_blocks
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_web_cidr_blocks
  }

  ingress {
    description = "Kubernetes API"
    from_port   = 6443
    to_port     = 6443
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

  tags = { Name = "${local.name}-web" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "internal" {
  name_prefix = "${local.name}-internal-"
  description = "Unrestricted traffic between instances inside the VPC"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "all traffic from within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-internal" }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# SSH key pair
# ---------------------------------------------------------------------------
# Imported once and shared. In the reference implementation each module
# created its own, which is what produced the "key pair already exists"
# failure after an interrupted destroy: the key survived in AWS while local
# state moved on without it.
resource "aws_key_pair" "lab" {
  count      = var.ssh_public_key != "" ? 1 : 0
  key_name   = "${local.name}-key"
  public_key = var.ssh_public_key

  tags = { Name = "${local.name}-key" }
}

# ---------------------------------------------------------------------------
# IAM for lab nodes
# ---------------------------------------------------------------------------
# One role and instance profile, shared by every instance in the lab. Its
# ARN is stable across rebuilds, so nothing waits on IAM eventual
# consistency at the start of a build.
resource "aws_iam_role" "node" {
  name = "${local.name}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "${local.name}-node" }
}

resource "aws_iam_instance_profile" "node" {
  name = "${local.name}-node"
  role = aws_iam_role.node.name
}

# Session Manager. Worth having even with SSH configured: it is the way in
# when a security group change locks you out of port 22.
resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# cert-manager solves the ACME DNS-01 challenge with these, using the
# instance role - no static credentials on the node. Scoped to this lab's
# hosted zone; the two account-wide actions are read-only lookups that
# cannot be scoped to a zone.
resource "aws_iam_role_policy" "node_route53" {
  count = local.zone_id != "" ? 1 : 0
  name  = "${local.name}-certmanager-route53"
  role  = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
        Resource = "arn:aws:route53:::hostedzone/${local.zone_id}"
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZonesByName", "route53:ListHostedZones"]
        Resource = "*"
      }
    ]
  })
}

# Read and write the lab-data prefix of the state bucket. This is what lets
# a node back its TLS certificate up before destroy and restore it on the
# next build, instead of asking Let's Encrypt for a new one every rebuild
# and running into the duplicate-certificate limit.
resource "aws_iam_role_policy" "node_labdata" {
  count = var.state_bucket != "" ? 1 : 0
  name  = "${local.name}-labdata"
  role  = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.state_bucket}/labdata/${var.environment}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.state_bucket}"
        Condition = {
          StringLike = { "s3:prefix" = ["labdata/${var.environment}/*"] }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Optional persistent Elastic IPs
# ---------------------------------------------------------------------------
# Empty by default. See the cost note on persistent_eip_names in
# variables.tf - the trade-off is not what it looks like.
resource "aws_eip" "persistent" {
  for_each = toset(var.persistent_eip_names)
  domain   = "vpc"

  tags = { Name = "${local.name}-${each.key}" }
}
