# suse-aws-hybrid-lab

A demo environment in AWS for SUSE and Rancher Government Solutions
products, driven from a laptop with bash, OpenTofu and the AWS CLI.

**v1:** a single-node Rancher Manager (RKE2 on SL-Micro, images from the
Carbide Secured Registry) reachable over HTTPS on a real DNS name.

**Later:** Harbor, SUSE Security, SUSE Observability and whatever comes
next — added by dropping in a component directory, with no changes to the
control script.

Two audiences: customers who want to see the product working, and SAs and
engineers who want to see how it is put together. The code and the READMEs
are meant to be read.

---

## The idea

Everything deployable is a **component**: a directory under `components/`
with a manifest. `Scripts/democtl` discovers them at runtime, works out what
is enabled, orders them by dependency, and runs each one's lifecycle.
Nothing about any specific product is hardcoded in the control script.

```
components/
├── _template/          copy-me skeleton, never deployed
├── foundation/         VPC, security groups, key pair, IAM   (persistent)
└── rancher-manager/    RKE2 + Rancher on SL-Micro            (ephemeral)
```

Adding a product:

```bash
Scripts/democtl new-component harbor
# edit components/harbor/, add its block to terraform.tfvars
Scripts/democtl build
```

## Two tiers, and why

Everything is either **persistent** or **ephemeral**, set by `LIFECYCLE` in
each manifest.

**Persistent** is free or costs pennies, is created once, and survives
teardown: the VPC, security groups, the SSH key pair, IAM roles, and the S3
bucket holding state and lab data. Managed only by `democtl foundation`.

**Ephemeral** is everything billed by the hour: instances, their volumes,
their public addresses, DNS records pointing at them, anything running on a
cluster. `democtl build` and `democtl destroy` act on exactly this tier.

With nothing ephemeral running, the lab costs **S3 storage only**. That is
the whole point of the split — tearing down should be cheap and rebuilding
should be fast, so neither is something you put off.

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars          # every ##UPDATE## marker

Scripts/democtl preflight         # tools, credentials, DNS, versions
Scripts/democtl foundation up     # persistent tier, once
Scripts/democtl build             # the lab
Scripts/democtl urls
```

Tearing down:

```bash
Scripts/democtl destroy           # ephemeral only; foundation stays
```

## Requirements

| | |
|---|---|
| OS | macOS or Linux |
| bash | **3.2 is supported** — the version macOS ships. No Homebrew bash needed. |
| OpenTofu | 1.11+ (for S3 native state locking; 1.5+ works without it) |
| AWS CLI | v2, with working credentials from the standard chain (`AWS_PROFILE`, SSO, env) |
| python3 | Used to filter `terraform.tfvars` per component and to parse JSON |
| AWS | A **public** Route53 hosted zone for `<subdomain>.<root_domain>` |
| Carbide | Portal credentials for `registry.ranchercarbide.dev` |

This repo never stores, prompts for, or writes an AWS key.

## Commands

```
list                    every component: lifecycle, enabled, deployed
status                  one health line per component
urls                    every product URL in one place
output [component]      OpenTofu outputs
versions                check rke2/rancher/cert-manager pinning against what is published
preflight               everything build needs, checked before it needs it

foundation up|status|down --i-mean-it     the persistent tier

build [--only X] [--with X,Y] [--dry-run]
destroy [--only X] [--dry-run]
plan [component]

ssh <component>
new-component <name>
```

`--dry-run` prints the ordered plan and changes nothing. Use it to see where
a new component lands before you build it.

## Configuration

One gitignored `terraform.tfvars` at the repo root holds everything, grouped
by which component owns it. You never pass it to OpenTofu yourself: `democtl`
writes each component a `democtl.auto.tfvars` containing only the variables
that component declares — which is why OpenTofu never prints a wall of
`Value for undeclared variable` warnings here.

- `common-vars.tf` holds **global** variables, symlinked into each component.
- A component's own settings live in **its** `variables.tf`.
- Secrets are `sensitive = true` and are never echoed by `democtl`.

## Things this repo already knows

Learned the hard way in the predecessor repo, and encoded here rather than
left to be rediscovered:

- **Pin `rke2_version`.** "Latest stable" is currently *above* the Rancher
  chart's Kubernetes ceiling, so an unpinned install fails at
  `helm install rancher` — twelve minutes into an otherwise healthy
  bootstrap. `democtl versions` checks the pairing against the published
  chart index.
- **Pin the SL-Micro minor version.** `suse-sle-micro-6-*` with
  `most_recent` sorts by publication date, so a freshly published 6.0 image
  beats an older 6.1 one and you silently get the older minor version.
- **SL-Micro's `/` is read-only** and cloud-init runs user-data with `$HOME`
  unset, so Helm resolves its config directory relative to `/` and fails.
  `export HOME=/root` at the top of every user-data script.
- **One wildcard certificate** for the whole lab. Let's Encrypt limits
  duplicates to 5 per week per exact set of names; a shared wildcard means
  one budget for every product instead of one per product, and a component
  added later needs no certificate work at all.
- **Every public IPv4 costs about $3.65/month**, including the one an
  instance gets automatically. A persistent Elastic IP is not more expensive
  while the lab runs — only while it is off.
- **RKE2 has no default StorageClass**, unlike K3s. Any component with PVCs
  installs `local-path-provisioner` or declares its own.
- **Tag everything.** `democtl orphans` finds strays by the `Environment`
  tag, and interrupted destroys do leave strays.

## Layout

```
SPEC.md                    what this is and why, plus the decision log
common-vars.tf             global variables, symlinked into each component
terraform.tfvars.example   every setting, grouped by component
Scripts/
  democtl                  the control script: a dispatcher, no product knowledge
  lib/
    common.sh              logging, guards, repo location - the entry point
    components.sh          discovery, manifests, dependency ordering
    tfvars.sh              reading terraform.tfvars, per-component var files
    aws.sh                 identity, Route53, the state bucket
    tofu.sh                running OpenTofu, running hooks
    tfvars_filter.py       the per-component variable filter
    check_versions.py      the rke2/Rancher/cert-manager coupling check
components/
  _template/               read components/_template/README.md before adding one
  foundation/
```
