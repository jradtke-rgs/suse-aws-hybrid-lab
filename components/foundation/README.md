# `foundation` — the persistent tier

**Lifecycle:** `persistent` · **Mandatory:** yes · **Order:** 10

Everything the lab needs that is free (or nearly), slow to recreate, or
prone to drift. `democtl build` and `democtl destroy` never touch it. It is
managed only by:

```bash
Scripts/democtl foundation up        # create or reconcile
Scripts/democtl foundation status    # what exists
Scripts/democtl foundation down --i-mean-it
```

## What it creates

| Resource | Why it is here rather than in an ephemeral component |
|---|---|
| VPC, one public subnet per AZ, IGW, route table | Free. Recreating them each build adds minutes of churn and saves nothing. |
| Security groups: `ssh`, `web`, `internal` | Free, and shared — a component attaches what it needs and adds its own group for anything specific. |
| EC2 key pair, imported from `ssh_public_key` | One key for the whole lab. In the reference implementation each module created its own, which is exactly how an interrupted destroy produced a `key pair already exists` failure on the next build. |
| IAM role + instance profile `<env>-node` | Stable ARNs, so nothing waits on IAM eventual consistency at the start of every build. Grants SSM, cert-manager's Route53 DNS-01, and read/write on the lab-data prefix. |
| Elastic IPs (optional, off) | See the cost note below. |

## What it deliberately does not create

**The S3 bucket.** It is created and configured by the AWS CLI inside
`democtl foundation up`, before any OpenTofu runs. Two reasons:

1. This component's own state lives in that bucket. A component that managed
   the bucket would be managing the thing holding its own state — and every
   way out of that knot (local state kept outside the checkout, a
   `init -migrate-state` dance on first apply, a separate bootstrap module)
   adds a special case to state handling, `orphans`, and teardown.
2. A `destroy` typo should never be able to delete state history.

Because the bucket exists before the first `tofu init`, **every component
including this one uses the S3 backend from its very first apply**. There is
no bootstrap exception anywhere in the repo and no state file in a checkout.

**The Route53 hosted zone.** Referenced, never managed. The zone outlives the
lab and may have other delegations under it.

## Cost

With nothing ephemeral running, the persistent tier costs **S3 storage only**
— pennies per month at lab scale. VPC, subnets, internet gateway, security
groups, key pairs, IAM roles and instance profiles are all free.

The one exception is `persistent_eip_names`, and the trade-off is not the
obvious one:

> AWS bills **every** public IPv4 address at about **$3.65/month**, including
> the one an instance is assigned automatically. A persistent Elastic IP
> therefore costs **nothing extra while the lab is running** — you would pay
> the same for the automatic address. What it costs is $3.65/month per
> address **while the lab is torn down** and the address sits idle.
>
> So the real question is not "is a stable IP worth $3.65/month" but "is
> skipping a DNS update on each build worth $3.65/month for every month the
> lab is off". Default is empty: update the A record instead.

## Outputs

Consumed by ephemeral components through `terraform_remote_state`. Renaming
one breaks every component that reads it.

| Output | Use |
|---|---|
| `vpc_id`, `vpc_cidr` | Security group rules |
| `public_subnet_ids` | Where to place an instance |
| `availability_zone` | The single AZ everything defaults to |
| `ssh_security_group_id`, `web_security_group_id`, `internal_security_group_id` | Attach to an instance |
| `key_pair_name` | `key_name` on an instance (empty when `ssh_public_key` is unset) |
| `instance_profile_name`, `node_role_arn` | `iam_instance_profile` on an instance |
| `route53_zone_id` | A records, and cert-manager's DNS-01 solver |
| `persistent_eip_ids`, `persistent_eip_addresses` | Maps keyed by the label in `persistent_eip_names` |
| `labdata_prefix` | Where to back up anything that should survive a rebuild |

## Adding a second availability zone

Add it to `availability_zones` in `terraform.tfvars`. A second subnet appears
with the next `/20` out of `vpc_cidr`; nothing else changes and no existing
subnet is touched. This exists because EKS requires two AZs — for anything
else, one AZ avoids cross-AZ data charges for resilience nobody is going to
test in a demo.

## Caveats

- `democtl foundation down` refuses to run while any ephemeral component is
  still deployed, and requires both `--i-mean-it` and typing the environment
  name. It does **not** delete the S3 bucket or the hosted zone; the command
  to remove the bucket is printed if you want it.
- Security group rules come from `allowed_ssh_cidr_blocks` and
  `allowed_web_cidr_blocks`, which default to `0.0.0.0/0` so a first run
  works from anywhere. That leaves SSH and the Kubernetes API open to the
  internet. Narrow them.
