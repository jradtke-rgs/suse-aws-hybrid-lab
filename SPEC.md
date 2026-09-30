# SPEC.md — RGS Demo Platform (AWS)

> **Working name:** `rgs-demo-platform` (placeholder — rename freely; it becomes
> the default `environment` value, the resource name prefix, and the AWS tag
> used for cleanup).
>
> **Reference implementation:** `../rgs-demo-aws`
> (https://github.com/jradtke-rgs/rgs-demo-aws). Read it, borrow from it, **do
> not modify it.** Its `ProjectSpec.md` and `CLAUDE.md` hold a decision log of
> problems that were confirmed live — treat those findings as requirements
> (summarized in §9).

---

## 1. Goal

Deploy a demo environment in AWS for Rancher Government Solutions (RGS)
products, driven entirely from a local workstation with bash + OpenTofu + the
AWS CLI.

- **v1:** a single-node **Rancher Manager** (RKE2 on SL-Micro, images from
  Carbide), reachable over HTTPS on a real DNS name.
- **Later:** add related products — **Harbor**, **SUSE Security**
  (NeuVector), **SUSE Observability**, and others not yet named — **without
  restructuring the repo or editing the control script's core logic.**

The main difference from `rgs-demo-aws` is **extensibility**. In the
reference repo, the module list is hardcoded (`PROJECTS=(...)` in `rgsctl`,
hostnames in `common-vars.tf`, hostnames again in `orphans`). Here, adding a
product means **dropping in a new component directory**, with no other
changes.

Audience: potential RGS customers (show the product working) and SAs/engineers
(learn how to put it into practice). Code and READMEs should be readable as
teaching material.

**Guiding principle — the smallest possible cloud footprint.** Run only what
must run in AWS, only while it's in use. Everything is either
**persistent** (cheap or free, survives lab rebuilds, rarely touched) or
**ephemeral** (compute, created and destroyed freely). Rebuilding the lab
should be fast, cheap, and not burn through rate limits or leave strays. See
§4.5.

## 2. Operating Assumptions

| Item | Assumption |
|---|---|
| Where it runs | macOS or Linux workstation, bash (must work with macOS's bash 3.2 **or** state clearly that `brew install bash` is required — pick one and enforce it in preflight) |
| AWS auth | Already set up locally. Uses the standard AWS CLI credential chain (`AWS_PROFILE`, SSO, env vars). **The repo never stores or prompts for AWS keys.** |
| IaC | OpenTofu (`tofu`; set the minimum version by whether S3 native locking is used). State for every component except `foundation` lives in the persistent S3 bucket (§4.5); `foundation` itself uses local state (bootstrap) |
| Region / AZ | Single region, single AZ, no NAT Gateway — cost over resilience |
| DNS | Existing Route53 **public** hosted zone for `<subdomain>.<root_domain>` |
| TLS | Let's Encrypt via cert-manager, DNS-01 against Route53 |
| Software source | RGS Carbide Secured Registry (`registry.ranchercarbide.dev`), with Carbide Portal credentials |
| Connectivity | Internet-connected (not air-gapped). No Hauler in v1. |
| Cost posture | The smallest instance types that actually work; everything torn down by one command |

## 3. Non-Goals (v1)

- Production hardening, HA Rancher, multi-AZ
- Air-gap / Hauler workflows (the architecture should not rule them out later)
- DynamoDB state locking (single operator; use S3 native lockfile if the installed OpenTofu supports it)
- CI/CD pipelines
- Running anywhere other than AWS

## 4. Architecture

### 4.1 Core idea: components

Everything deployable is a **component**: a self-contained directory under
`components/` with a small manifest. The control script (`Scripts/rgsctl`)
**discovers** components at runtime. It works out which are enabled, orders
them by dependency, and runs each one's lifecycle. Nothing about a specific
product is hardcoded in `rgsctl`.

```
<repo>/
├── SPEC.md                      # this file
├── CLAUDE.md                    # generated during build-out (see §10)
├── README.md
├── common-vars.tf               # GLOBAL variables only (region, env, owner, DNS, Carbide, LE, SSH)
├── terraform.tfvars.example     # all variables, grouped by component, ##UPDATE## markers
├── .gitignore                   # carry over from rgs-demo-aws
├── Scripts/
│   ├── rgsctl                   # entry point: thin dispatcher
│   └── lib/                     # sourced helpers (log.sh, tfvars.sh, components.sh, aws.sh, ...)
└── components/
    ├── _template/               # copy-me skeleton for new components (never deployed)
    ├── foundation/              # PERSISTENT: state + lab-data buckets, VPC/SGs, key pair, IAM, SSM (mandatory)
    ├── rancher-manager/         # EPHEMERAL: RKE2 + Rancher on SL-Micro (mandatory)
    ├── rancher-cloud-credential/# IAM user/key for Rancher node + EKS drivers (optional, v1.1)
    ├── harbor/                  # future
    ├── suse-security/           # future
    └── suse-observability/      # future
```

> Deliberate deviation from the reference: components live under
> `components/` rather than at the repo root, so discovery is a simple glob and
> the repo root stays clean. Relative paths therefore change
> (`../../common-vars.tf`, `-var-file=../../terraform.tfvars`).

### 4.2 Component contract

Every component directory contains:

| File | Required | Purpose |
|---|---|---|
| `component.conf` | **yes** | Shell-sourceable manifest (see below) |
| `README.md` | **yes** | What it deploys, how to reach it, manual steps, known caveats |
| `main.tf`, `variables.tf`, `outputs.tf` | if `KIND` includes `tofu` | OpenTofu root module |
| `common-vars.tf` | if `tofu` | **Symlink** to `../../common-vars.tf` |
| `hooks/*.sh` | optional | Lifecycle hooks (below) |
| `templates/` | optional | `templatefile()` inputs (user-data, manifests, Helm values) |

**`component.conf`** — plain `KEY=value` lines. `rgsctl` reads it with a
parser, **not** with `source`, so a component can't execute code at
discovery time.

```bash
NAME=harbor
DESCRIPTION="Harbor container registry"
ORDER=40                    # tie-breaker / coarse ordering; lower runs first
DEPENDS_ON="foundation rancher-manager"
MANDATORY=false
ENABLE_VAR=enable_harbor    # bool in terraform.tfvars; ignored when MANDATORY=true
KIND=tofu+hooks             # tofu | hooks | tofu+hooks | docs
LIFECYCLE=ephemeral         # persistent | ephemeral  (see §4.5)
HOSTNAME_VAR=hostname_harbor  # optional; used by `urls` and `orphans` DNS checks
```

**Lifecycle hooks** (all optional, run from the component directory,
receive the environment described below):

| Hook | When |
|---|---|
| `hooks/preflight.sh` | During `rgsctl preflight` / before `build` — validate required vars, credentials, licenses |
| `hooks/post-apply.sh` | After `tofu apply` succeeds (e.g. Helm install onto an existing cluster, waiting for readiness) |
| `hooks/pre-destroy.sh` | Before `tofu destroy` (e.g. delete LoadBalancer services, cluster-side resources that would strand AWS objects) |
| `hooks/urls.sh` | Prints `label<TAB>url` lines for `rgsctl urls` |
| `hooks/status.sh` | Prints a one-line health summary for `rgsctl status` |

**Hook environment:** `rgsctl` exports `REPO_ROOT`, `COMPONENT_DIR`,
`COMPONENT_NAME`, `TFVARS_FILE`, `ENVIRONMENT`, `AWS_REGION`, plus a helper
path so hooks can `source "$REPO_ROOT/Scripts/lib/common.sh"` for logging and
`get_tfvar`. A hook that needs another component's outputs calls
`component_output <name> <output>` (a lib function wrapping
`tofu -chdir=... output -raw`). **Do not reach into sibling state files by
path from bash.**

**Cross-component data in OpenTofu:** `terraform_remote_state` with the
**S3 backend** (bucket/region passed in as variables that `rgsctl`
provides, key `<environment>/<dependency>/terraform.tfstate`). Only for
components listed in `DEPENDS_ON`. `foundation`'s outputs are the exception:
its state is local, so `rgsctl` exports the few values dependents need
(bucket names, VPC/subnet/SG IDs, IAM instance profile names) into a
generated, gitignored `foundation.auto.tfvars.json` that it passes to every
ephemeral component. *Reviewer: if you'd rather migrate `foundation`'s own
state into the bucket after the first apply (`tofu init -migrate-state`) so
every component reads remote state the same way, recommend it.*

**Tagging:** every AWS resource gets default tags `Environment`, `Project`,
`Component` (= `NAME`), `ManagedBy=opentofu`, `Owner`. `orphans` relies on
these.

### 4.3 Variables and configuration

- **One** gitignored `terraform.tfvars` at the repo root, as in the
  reference. It holds globals and every component's settings, grouped by
  component with header comments.
- `common-vars.tf` = **global** variables only (region, environment, owner,
  VPC/AZ, allowed CIDRs, SSH key, DNS/root_domain/subdomain/zone_id, Carbide
  registry + creds, Let's Encrypt, `ami_id`, `rke2_version`).
- Component-specific variables (versions, instance types, hostnames, licenses,
  `enable_<name>`) live in **that component's `variables.tf`**.
- **Known wrinkle:** passing one shared var-file to modules that don't declare
  every variable produces "undeclared variable" warnings in OpenTofu. Pick and
  document one approach:
  1. accept and suppress the warnings in `rgsctl` output, **or**
  2. have `rgsctl` generate a per-component `.auto.tfvars` holding only the
     keys that component declares (parsed from its `variables.tf` +
     `common-vars.tf`), **or**
  3. declare all `enable_*` flags globally and keep other component vars local.

  *Preference: option 2 if it stays simple and robust; otherwise option 1.
  Reviewer: recommend one.*
- `terraform.tfvars.example` must stay complete. Adding a component means
  adding its block to the example (the `_template` README says so).
- Secrets (Carbide password, licenses, admin passwords) are `sensitive = true`
  and never echoed by `rgsctl`.

### 4.4 Enabling components

- `MANDATORY=true` components always deploy (`foundation`,
  `rancher-manager`); `build` fails fast with a pointer to
  `rgsctl foundation up` if the foundation isn't there.
- Optional components deploy when `<ENABLE_VAR> = true` in `terraform.tfvars`.
- CLI override for one run: `rgsctl build --only harbor` /
  `rgsctl build --with harbor,suse-security` (dependencies are pulled in
  automatically; mandatory components are assumed present).
- `rgsctl` refuses to run if an enabled component depends on a disabled one,
  and prints what to enable.

### 4.5 Persistence tiers — what survives a rebuild

Two tiers, set by `LIFECYCLE=` in each manifest. **`rgsctl build` and
`rgsctl destroy` only touch `ephemeral` components.** Persistent components
are managed with `rgsctl foundation up|down|status`. `down` requires typing
the environment name **and** `--i-mean-it`, and warns about data loss (S3
contents).

**Persistent tier** — free or pennies per month, created once:

| Item | Why it persists | Cost |
|---|---|---|
| Route53 public hosted zone | Already exists; **outside this repo** (referenced, never created or destroyed) | existing |
| S3 bucket: **OpenTofu state** (versioned, encrypted, public access blocked) | State survives clone/archive cycles. **This removes the sibling-directory scan problem** from `rgs-demo-aws` (§9 #10): state no longer lives in the checkout | ~free |
| S3 bucket (or prefix): **lab data** — TLS cert backups, Rancher backups, future Harbor registry storage | Keeps expensive-to-recreate data (see below) | ~free at lab scale |
| SSM Parameter Store (SecureString, standard tier): Carbide creds, licenses, admin passwords — *optional* | Secrets stop living only in a local tfvars file; user-data fetches them at boot instead of embedding them in EC2 user-data (user-data is readable by anyone with `ec2:DescribeInstanceAttribute`) | free (standard tier) |
| EC2 key pair (imported from `ssh_public_key`) | No "key pair already exists" drift after interrupted destroys | free |
| IAM: roles/policies/instance profiles that ephemeral instances attach (cert-manager DNS-01, SSM, S3 access to the lab-data bucket) | Stable ARNs, no IAM eventual-consistency waits on every rebuild | free |
| VPC, subnet(s), IGW, route table, security groups (no NAT GW) | Free in AWS; recreating them each time adds time and churn for no saving | free |
| *Optional:* Elastic IP for Rancher (`persist_rancher_eip`, default **false**) | Stable IP → DNS never changes. **Not free:** AWS bills every public IPv4 (~$3.60/mo), attached or idle. Default off; the A record is updated on each build instead | ~$3.60/mo |

**Ephemeral tier** — everything that bills by the hour: EC2 instances,
their EBS volumes, public IPs (unless persisted), Route53 **A records** for
ephemeral hosts, anything created on a cluster. `rgsctl destroy` must leave
the persistent tier untouched, and `orphans` must be clean afterwards.

**Data that should come back after a rebuild** (implement as part of
`rancher-manager` hooks/user-data; mark each one *verify live*):

1. **Let's Encrypt certificate + key.** Before destroy (`pre-destroy` hook)
   or right after issuance, export the TLS Secret (and the ACME account key
   Secret) to the lab-data bucket (SSE encrypted). At next boot, restore them
   **before** cert-manager reconciles, so cert-manager sees a valid cert and
   doesn't re-issue. This is the fix for §9 #4 (LE's duplicate-cert rate
   limit), and it's what makes `letsencrypt_environment = "production"` safe
   to use by default.
2. **Rancher configuration** (optional, `persist_rancher_config`, default
   false for v1): install `rancher-backup` with an S3 target in the lab-data
   bucket; `pre-destroy` triggers a one-time Backup; at next build, a Restore
   runs if a backup exists. Only worthwhile once downstream clusters and
   settings are worth keeping; document the version-compatibility caveat
   (restore to the same Rancher version).
3. **Harbor images** (future): registry storage backend = the lab-data bucket,
   so pushed/mirrored images survive rebuilds.

**Ways to keep compute to a minimum** (all optional, all in tfvars):
- `rgsctl stop` / `rgsctl start`: stop/start ephemeral instances without
  destroying them (you pay only for EBS while stopped). Handle the public IP
  changing on start (update the A record) when no EIP is persisted.
- Spot instances for ephemeral nodes (`use_spot = false` by default). Explain
  the interruption trade-off in the README.
- An optional **idle auto-stop** (e.g. an instance-local timer or EventBridge
  Scheduler stop at a set hour) — design it but ship it off by default.
  *Reviewer: say whether this belongs in v1.*
- `rgsctl cost`: print the running ephemeral instances with type, uptime, and
  a rough hourly cost (hardcoded price table is fine, clearly labeled as
  approximate).

**Bootstrap order:** `foundation` (local state, never committed, kept
**outside the checkout** at a configurable path — see §9 #10; `rgsctl
foundation backup-state` copies it into the state bucket it just created) →
every other component uses the S3 backend with key
`<environment>/<component>/terraform.tfstate`. `rgsctl` generates each
component's backend config (`-backend-config=`) so no bucket name is
hardcoded in `.tf` files.

## 5. `rgsctl` — Control Script

Keep the reference's UX (colored `print_msg`/`print_header`, confirmation on
destroy, helpful errors), but split into `Scripts/lib/*.sh` so no single file
reaches 800 lines.

| Command | Behavior |
|---|---|
| `rgsctl list` | Table of discovered components: name, mandatory/enabled, order, deps, deployed? (state present + non-empty) |
| `rgsctl preflight` | Tools present (`tofu`, `aws`, `jq` or `python3`, `helm`/`kubectl` if any enabled component needs them); `aws sts get-caller-identity` succeeds; **public** Route53 zone visible (port `checkdns` from reference); `terraform.tfvars` exists with no `##UPDATE##` placeholders left; each enabled component's `hooks/preflight.sh` |
| `rgsctl foundation up\|down\|status\|backup-state` | Manage the **persistent** tier only (§4.5). `down` is guarded (type env name + `--i-mean-it`) and lists what data will be lost. |
| `rgsctl build [--only X] [--with X,Y]` | `preflight`, then for each enabled **ephemeral** component in dependency order: `tofu init` (S3 backend) → `tofu apply -auto-approve` → `post-apply` hook. Stop on first failure with a clear message naming the component. Print `urls` at the end. |
| `rgsctl plan [component]` | `tofu plan` for one or all enabled components |
| `rgsctl destroy [component]` | **Ephemeral only.** **Reverse** dependency order: `pre-destroy` hook (e.g. back up the TLS secret) → `tofu destroy`. Confirmation prompt (type the environment name). Refuse to destroy a component while a deployed component depends on it, unless `--force`. |
| `rgsctl stop` / `rgsctl start` | Stop/start ephemeral EC2 instances; on `start`, update A records if the IP changed; `status` shows stopped state |
| `rgsctl cost` | Running ephemeral instances with type, uptime, approximate $/hr (§4.5) |
| `rgsctl output [component]` | `tofu output` per component |
| `rgsctl urls` | Aggregate each component's `hooks/urls.sh` (fall back to a `*_url` output if present) |
| `rgsctl status` | Aggregate `hooks/status.sh` |
| `rgsctl getkube` | Fetch Rancher Manager's kubeconfig (as in reference), rewrite the server to the public FQDN, save to `~/.kube/<environment>.yaml`, print the `export KUBECONFIG=` line |
| `rgsctl ssh <component>` | SSH using the component's `ssh_command` output |
| `rgsctl orphans [--delete]` | Port from reference, but **component-driven**: collect known IDs from every component's state (the S3 state plus `foundation`'s local state — no sibling-dir scan needed any more); DNS checks iterate `HOSTNAME_VAR` from manifests rather than a hardcoded list. Never flags or deletes persistent-tier resources that are in `foundation`'s state. |
| `rgsctl new-component <name>` | Copy `_template` → `components/<name>`, substitute the name, create the `common-vars.tf` symlink, print the next steps |
| `rgsctl help` | Usage, generated partly from discovered components |

Dependency ordering: topological sort on `DEPENDS_ON`, `ORDER` as
tie-breaker, cycle detection with an error. Implement in bash (or a small
embedded `python3` snippet — the reference already requires python3; decide
and be consistent).

## 6. Components — v1 Scope

### 6.1 `foundation` (mandatory, `LIFECYCLE=persistent`, ORDER=10)

Takes over from the reference's `shared-services` and adds the persistent
items from §4.5:
- VPC, one public subnet (single AZ), IGW, route table, shared SSH SG,
  internal SG. No NAT GW (flag kept for the future). Port from reference.
- S3 state bucket + lab-data bucket (versioning, SSE-S3, block public access,
  lifecycle rule expiring old object versions after N days to keep cost ~0)
- EC2 key pair from `ssh_public_key`
- IAM role + instance profile for `rancher-manager` (SSM core, cert-manager
  Route53 DNS-01 scoped to the zone, read/write on the lab-data bucket's
  prefixes, read on the SSM parameter path if used)
- Optional SSM SecureString parameters under `/<environment>/...`
- Optional persistent EIP (`persist_rancher_eip`)
- Outputs: `vpc_id`, `public_subnet_ids`, `ssh_security_group_id`,
  `internal_security_group_id`, `availability_zone`, `state_bucket`,
  `labdata_bucket`, `key_pair_name`, `rancher_instance_profile`,
  `rancher_eip_allocation_id` (nullable)

Also expose any **extra subnets or CIDR room** future components may need
(e.g. a second AZ subnet so an EKS component can be added later — EKS
requires two AZs). Leave it off by default but design the variable now.

### 6.2 `rancher-manager` (mandatory, `LIFECYCLE=ephemeral`, ORDER=20)

Port from reference:
- SL-Micro 6 BYOS AMI (`owner 013907871322`,
  `suse-sle-micro-6-*-byos-v*-hvm-ssd-x86_64`), override via `ami_id`
- Instance type variable (reference default `t3.large`; confirm it's the
  smallest that runs single-node RKE2 + Rancher well). Root volume: reference
  uses 100 GB gp3 encrypted — **right-size it** (EBS is billed even while
  stopped) and justify the number in the README
- Uses `foundation`'s instance profile, key pair, SGs, subnet (creates no IAM itself)
- Associates `foundation`'s EIP if persisted, otherwise uses the instance's
  public IP; Route53 A record `hostname_rancher.<subdomain>.<root_domain>`
  (ephemeral, short TTL like 60 s)
- TLS restore-before-issue and optional Rancher backup/restore (§4.5)
- `user-data.sh` (templatefile): RKE2 install with Carbide `registries.yaml`,
  Helm, cert-manager, Let's Encrypt ClusterIssuer/Certificate, Rancher Helm
  install, Carbide set as Rancher `system-default-registry` + registry
  credential Secret (non-fatal; see README fallback)
- Outputs: `rancher_url`, `rancher_hostname`, `public_ip`, `private_ip`,
  `instance_id`, `ssh_command`, `security_group_id`, `iam_role_arn`
- `hooks/post-apply.sh`: optionally wait (with timeout + progress) until
  `https://<rancher_fqdn>/ping` returns `pong`, replacing the reference
  README's manual 600 s countdown
- `hooks/urls.sh`, `hooks/status.sh`
- Print where to get the bootstrap password (the command that reads it over SSH)

**Structure `user-data.sh` for extensibility:** break it into clearly named
functions (`install_rke2`, `configure_registries`, `install_helm`,
`install_cert_manager`, `install_rancher`, `configure_system_default_registry`)
and log each step to `/var/log/rgs-bootstrap.log` with timestamps and a final
`BOOTSTRAP COMPLETE` / `BOOTSTRAP FAILED at <step>` marker that `status.sh` can
read over SSH.

### 6.3 `_template` (never deployed)

A minimal working example: `component.conf` with `MANDATORY=false`,
`LIFECYCLE=ephemeral`,
`ENABLE_VAR=enable_template` (the real template ships with `KIND=docs` so it's
inert), a stub `main.tf` that reads `foundation`'s outputs, commented
hook stubs, and a README checklist: *manifest → variables → tfvars.example
block → hooks → README → `rgsctl list` shows it.*

## 7. Future Components (design for, don't build in v1)

These tell you what the framework must be able to express. Build none of
them, but check that the contract in §4.2 can handle each one without
changes to `rgsctl`.

| Component | Likely shape | What it needs from the framework |
|---|---|---|
| `rancher-cloud-credential` | Tofu only: IAM user + access key for Rancher's EC2 node driver and EKS driver (port from reference) | Sensitive outputs; `urls`/`status` hooks irrelevant |
| `harbor` | Either Helm onto a dedicated small RKE2/K3s node (own EC2 + EIP + DNS) **or** onto Rancher Manager's local cluster. Needs TLS via the same cert-manager/LE pattern, S3 or EBS storage choice | Tofu + `post-apply` Helm; `HOSTNAME_VAR`; optional dependency for other components to use Harbor as a mirror |
| `suse-security` | NeuVector Helm chart (Carbide-sourced images) on a downstream cluster or on Rancher's local cluster for the smallest demo | Needs a *target cluster* concept (see open question Q3) |
| `suse-observability` | Helm chart pinned to a version whose images Carbide has synced; needs a downstream cluster sized ≥ `m5.4xlarge`, `local-path-provisioner`, license + admin password | Target cluster, large instance, license preflight, long post-apply wait |
| `downstream-cluster-*` | A downstream RKE2 cluster, created either with OpenTofu directly or through Rancher (`rancher2` provider / node driver) | Cross-component output: a kubeconfig or cluster ID others can target |
| `eks` | Rancher EKS driver or native `aws_eks_cluster` | Two-AZ subnets from `foundation` |

## 8. Requirements Checklist

**Functional**
- [ ] `rgsctl build` on a fresh clone with a filled-in `terraform.tfvars`
      produces a working Rancher Manager at `https://rancher.<subdomain>.<root_domain>`
      with a valid Let's Encrypt cert (staging or production per var)
- [ ] `rgsctl destroy` removes every ephemeral resource and leaves the persistent tier intact; `rgsctl orphans` afterwards reports nothing
- [ ] **Rebuild test:** `build` → `destroy` → fresh clone in a new directory → `build` again reuses the same state bucket, VPC, key pair, and IAM, and **does not request a new Let's Encrypt certificate** (restored from backup)
- [ ] With nothing ephemeral running, the account's lab-related cost is only the S3 storage (+ the EIP if `persist_rancher_eip = true`) — documented in the README
- [ ] `rgsctl stop` → `start` brings Rancher back at the same FQDN
- [ ] `rgsctl foundation down` removes the persistent tier cleanly (after emptying buckets, with explicit confirmation)
- [ ] `rgsctl new-component foo` → edit → `enable_foo = true` → `rgsctl build`
      deploys `foo` with **zero edits** to `Scripts/`
- [ ] Disabling an optional component and re-running `build` does not touch it
      (documented: use `rgsctl destroy <name>` to remove it)
- [ ] Re-running `build` is idempotent (no changes on second run)

**Non-functional**
- [ ] `shellcheck` clean on `Scripts/**` and `hooks/**` (`set -euo pipefail` in scripts; hooks too)
- [ ] `tofu fmt -check` and `tofu validate` clean for every tofu component
- [ ] No secrets in git, in `rgsctl` output, or in `ps`-visible command lines
- [ ] Every component has a README with: purpose, cost note (instance types), URLs, manual steps, caveats
- [ ] Parameterized: domain, hostnames, instance types, volume sizes, versions, LE email/env, CIDRs, region/AZ

## 9. Lessons From `rgs-demo-aws` — Treat as Requirements

Confirmed live in the reference repo; don't relearn them.

1. **SL-Micro `/` is read-only** and cloud-init runs user-data with `$HOME`
   unset → Helm fails with `mkdir .config: read-only file system`. Put
   `export HOME=/root; cd /root` at the top of every user-data script.
   `/root`, `/var`, `/usr/local` are writable.
2. **Version coupling:** `rancher_version`, `cert_manager_version`, and
   `rke2_version` (empty = latest stable) must be compatible. Rancher's chart
   pins a `kubeVersion` ceiling; cert-manager supports a rolling k8s window.
   Keep the coupling comments, and have `preflight` warn if `rke2_version` is
   empty ("latest stable may exceed Rancher's ceiling"). Verify current
   versions at build time — the reference's `2.14.3` / `1.21.1` are starting
   points, not truths.
3. **Carbide registry is `registry.ranchercarbide.dev`** (Harbor-backed).
   `rgcrprod.azurecr.us` is wrong/legacy. Harbor returns 401/403 for both bad
   creds *and* missing repo/tag — check `/v2/_catalog` and
   `/v2/<repo>/tags/list` before blaming entitlement.
4. **Let's Encrypt production rate limit** (5 duplicate certs / exact
   hostname / 7 days). The cert backup/restore in §4.5 is the main fix.
   Until it's verified live, default `letsencrypt_environment = "staging"`
   and have `preflight` warn when it's `production` and no cert backup
   exists in the lab-data bucket.
5. **RKE2 has no default StorageClass** (unlike K3s). Any component with PVCs
   installs `local-path-provisioner` or declares a StorageClass dependency.
6. **Observability sizing:** `t3.2xlarge` hits `Insufficient cpu`;
   `m5.4xlarge` is the proven minimum for the non-HA profile. Pin the chart
   to a version whose images Carbide has actually synced.
7. **Rancher-driven downstream clusters** are the preferred pattern over
   "bare EC2 + import over SSH". Rancher node/EKS driver Cloud Credentials
   need **static** AWS keys (no assume-role option in the UI).
8. **Carbide as `system-default-registry`** in Rancher propagates auth to
   downstream nodes. Out-of-band `registries.yaml` on downstream nodes gets
   wiped by Rancher's plan reconciliation.
9. **Strict CA verification** on import flows (`CATTLE_AGENT_STRICT_VERIFY`,
   `agentEnvVars STRICT_VERIFY=false`) — only relevant if a component ever
   imports a cluster manually.
10. **Archive-before-clone workflow** left live state in sibling
    `<repo>-YYYY-MM-DD-NN/` dirs, and `orphans` had to scan them. Here, S3
    state makes clones stateless. The one remaining local file is
    `foundation`'s state: keep it outside the repo checkout (e.g.
    `~/.local/state/<environment>/foundation.tfstate`, path configurable) so
    archiving or re-cloning never strands it. *Reviewer: confirm, or
    recommend migrating it into S3.*
11. **Interrupted destroys leave strays** (e.g. key pairs). `orphans` exists
    for exactly this; tag everything.

## 10. Build Plan (for Claude Code)

Work in phases, and commit at the end of each one. Stop after Phase 0 for
review.

- **Phase 0 — Review (no code).** Read this spec and `../rgs-demo-aws`
  (`ProjectSpec.md`, `CLAUDE.md`, `Scripts/rgsctl`, `common-vars.tf`,
  `rancher-manager/`). Report: gaps or contradictions in this spec, answers or
  recommendations for §11's open questions, and anything in the reference
  that should carry over but isn't listed here. Propose the final repo tree.
- **Phase 1 — Skeleton.** Repo layout, `.gitignore`, `common-vars.tf`,
  `terraform.tfvars.example`, `Scripts/rgsctl` + `lib/` with `list`,
  `preflight`, `help`, `new-component`; `_template`. Discovery, manifest
  parsing, and topo sort implemented with a `--dry-run` for `build`/`destroy`
  that prints the plan without calling tofu.
- **Phase 2 — `foundation`.** Persistent tier, S3 backend wiring,
  `foundation up/status`, generated backend config. `tofu validate`, apply,
  confirm a second `up` is a no-op.
- **Phase 3 — `rancher-manager`.** Port, restructure `user-data.sh`, hooks.
  Full `build` → Rancher reachable → `getkube` → `destroy` → `orphans` clean.
- **Phase 3b — Persistence.** TLS cert backup/restore, `stop`/`start`,
  `cost`. Run the §8 rebuild test end to end. (Rancher backup/restore can
  slip to a later phase.)
- **Phase 4 — Hardening.** shellcheck, `tofu fmt`, README, generate
  `CLAUDE.md` (architecture, commands, conventions, "how to add a component",
  and the §9 lessons).
- **Phase 5 (separate effort).** First add-on component (suggest
  `rancher-cloud-credential`, since it's small and already proven) to show the
  extension path works end to end.

Rules while building:
- Don't run `tofu apply`/`destroy` or anything that creates AWS resources
  without asking first. `plan`, `validate`, and read-only AWS CLI calls are fine.
- Default `letsencrypt_environment = "staging"` during iteration.
- Record decisions and confirmed-live findings in a **Decision Log** section
  appended to this file (date, decision, why), the way the reference does.

## 11. Open Questions (reviewer: recommend answers)

1. **Var-file strategy** — §4.3 options 1/2/3.
2. **Bash version** — support macOS bash 3.2 (no associative arrays) or
   require bash ≥ 4 via Homebrew?
3. **Target-cluster concept** — Security/Observability/Harbor need "which
   cluster do I install onto?" Should the framework have a first-class
   `TARGET_CLUSTER=` manifest field that resolves to a kubeconfig (Rancher's
   local cluster, or a `downstream-cluster-*` component's output)? Or is that a
   hook-level concern?
4. **Downstream clusters** — created through OpenTofu (`rancher2` provider or
   raw EC2 + RKE2), or through the Rancher UI with docs only (the reference's
   current choice)? The former fits "one command," the latter fits "show
   customers how Rancher works."
5. **Rancher image/chart source** — public `rancher-stable` chart with Carbide
   images through `system-default-registry`, or a Carbide-hosted chart? (Still
   unverified in the reference.)
6. **Harbor placement** — dedicated node versus Rancher's local cluster.
7. **Project name / environment prefix / subdomain** — confirm before Phase 1.
8. **`foundation` state location** — local file outside the checkout, or
   migrated into its own S3 bucket after the first apply?
9. **Secrets** — SSM Parameter Store as the source of truth for Carbide
   creds and licenses (fetched at boot), or keep them only in
   `terraform.tfvars` like the reference? The first keeps secrets out of EC2
   user-data.
10. **Idle auto-stop** — v1 or later? Which mechanism?
11. **Persistent EIP** — worth ~$3.60/mo for a DNS name that never changes,
    or rely on short-TTL A-record updates?

---

## 12. Decision Log

Decisions and confirmed-live findings, newest first. The format follows the
reference repo: what was decided, and why.

### 2026-09-30 — Phase 0 review, and Phases 1–2

**Verified live against account `825121932802` (us-east-2), read-only calls:**

- Public hosted zone `suse-aws-hybrid-lab.kubernerdes.com` already exists
  (`Z01816481I38QSPQ2RMNF`). Confirms the project name below.
- SL-Micro AMI filter still valid for owner `013907871322`.
- Rancher stable chart: latest **2.15.2**, `kubeVersion < 1.37.0-0`.
- cert-manager: latest **1.21.2**.
- RKE2: latest non-prerelease **v1.37.0+rke2r1**.
- S3 bucket `suse-aws-hybrid-lab` already existed (created by the operator,
  unused, empty, SSE-S3 on, versioning off). Adopted rather than creating
  another.

**Findings that changed the design:**

1. **`rke2_version = ""` is broken two ways, not one.** RKE2 v1.37.0 is
   released and Rancher 2.15.2's chart caps at `< 1.37.0-0`, so "latest
   stable" now exceeds the ceiling and `helm install rancher` refuses the
   chart. Separately, `https://update.rke2.io/v1-release/channels` was
   returning **404** on this date while the k3s equivalent worked normally,
   so an unpinned installer could not resolve a version at all. Decision:
   pin `rke2_version = "v1.36.4+rke2r1"` with `rancher_version = "2.15.2"`
   and `cert_manager_version = "1.21.2"`, and add `democtl versions` to
   check the pairing against the published chart index rather than against a
   comment in a file.

2. **The SL-Micro AMI filter silently selects the wrong minor version.**
   `suse-sle-micro-6-*` with `most_recent = true` sorts by publication date;
   on this date the newest match was **6.0** (`v20260916`), ahead of 6.1
   (`v20260914`). Decision: add `sl_micro_version` (default `6-1`) so the
   filter is explicit. The same data source also breaks §8's idempotency
   requirement — a new publication turns a no-op build into an instance
   replacement — so instances will carry
   `lifecycle { ignore_changes = [ami] }` with an explicit way to force a
   rebuild.

3. **§4.5's Elastic IP cost note was wrong in a way that inverts the
   trade-off.** AWS bills every public IPv4 at ~$3.65/month, including the
   address an instance is assigned automatically. A persistent EIP costs
   nothing extra *while the lab runs*; it costs $3.65/month only *while the
   lab is down*. Kept off by default, but documented accurately.

4. **One wildcard certificate, not one per host.** Let's Encrypt's
   duplicate-certificate limit is 5 per week per exact set of identifiers, so
   `*.<subdomain>.<root_domain>` gives the whole lab a single budget instead
   of one per product, and every future component inherits TLS with no
   issuance work. DNS-01 is already required.

5. **Certificate restore has an ordering trap** worth recording before
   Phase 3b: restore the Secret *before* applying the Certificate CR,
   preserve its `cert-manager.io/*` annotations (without them cert-manager
   treats the Secret as unmanaged and re-issues anyway), and restore the ACME
   account key Secret too.

6. **`democtl start` must not write the A record directly.** Doing so is
   immediate state drift. It should start the instance, wait, then run
   `tofu apply` on the component so OpenTofu refreshes `public_ip` and
   updates the record itself.

**Open questions (§11), answered:**

| # | Decision |
|---|---|
| 1 | Var-file strategy: **option 2**. `democtl` generates a per-component `democtl.auto.tfvars` holding only the variables that component declares. Confirmed live: `tofu plan` on `foundation` emits zero `undeclared variable` warnings. The generator (`Scripts/lib/tfvars_filter.py`) also emits `tofu fmt`-clean output. |
| 2 | Bash: **target 3.2**, the version macOS ships. Parallel indexed arrays and linear scans instead of associative arrays; with a handful of components the cost is nil and the code reads better than `eval`-based maps. No Homebrew bash requirement. |
| 3 | Target cluster: **hook-level for v1**, with an optional `TARGET_CLUSTER=` manifest field reserved and documented so adding it later is not a breaking change. |
| 4 | Downstream clusters: **created by OpenTofu**, so "one command" holds. |
| 5 | Rancher source: **public `rancher-stable` chart, Carbide images via `system-default-registry`** — unchanged from the reference, still unverified. |
| 6 | Harbor: **on Rancher's local cluster**. A dedicated node doubles the EC2 bill for a demo. |
| 7 | Name: **`suse-aws-hybrid-lab`** — confirmed by the operator. Matches the repo and the hosted zone that already exists. The spec's `rgs-demo-platform` working name is retired. |
| 8 | Foundation state: **S3, from the very first apply** — see the bucket decision below. Neither option in the spec was needed. |
| 9 | Secrets: **`terraform.tfvars` only** for v1, matching the lab posture. SSM Parameter Store remains the honest pattern for a real deployment and is noted as such. |
| 10 | Idle auto-stop: design it, ship it off by default. |
| 11 | Persistent EIP: off by default, with the corrected cost framing above. |

**The S3 bucket is not managed by OpenTofu.** `democtl foundation up`
creates and configures it with the AWS CLI (versioning, encryption, public
access block, lifecycle) before any `tofu init` runs. This was decided after
the operator confirmed an existing bucket could be reused, and it is a
better answer than either option Q8 offered:

- It removes the bootstrap knot entirely. `foundation`'s own state lives in
  the bucket, so a component managing that bucket would be managing the thing
  holding its own state.
- **Every component, `foundation` included, uses the S3 backend from its
  first apply.** No local state anywhere, no `init -migrate-state` step, no
  `foundation.auto.tfvars.json` generator, no `backup-state` command, and no
  local-state branch in `orphans` — three special cases the spec had
  budgeted for, all deleted.
- A `destroy` typo can never remove state history.

The bucket is treated exactly like the Route53 zone: pre-existing
infrastructure the lab reads and writes but never creates in OpenTofu or
destroys. One bucket with two prefixes (`state/` and `labdata/`) rather than
two buckets — one thing to create, one lifecycle policy, one thing to empty.

**Renamed `rgsctl` to `democtl`** at the operator's request: the lab covers
SUSE products generally, not only RGS.

**Deviations from the spec, deliberate:**

- `Scripts/lib/common.sh` sources the rest of the library, so both `democtl`
  and every hook have one entry point — `. "$DEMOCTL_LIB/common.sh"` — as
  §4.2 describes.
- Security groups are shared from `foundation` (`ssh`, `web`, `internal`)
  rather than each component creating its own; a component adds its own group
  only for ports specific to it.
- One IAM role and instance profile (`<env>-node`) shared by all lab nodes,
  rather than one per component.
- `persistent_eip_names` is a list of labels rather than a single
  `persist_rancher_eip` bool, so a second component can have a stable address
  without a schema change.

### 2026-09-30 — Carbide generalized to an optional private registry

Corrected after the operator's repeated, explicit feedback that this is not
an RGS-specific project (the same reasoning behind the earlier
`rgsctl` → `democtl` rename): Carbide is RGS's own branded registry, not a
generic SUSE/Rancher concern, and requiring its credentials before any
build - even one that never touches an RGS product - was a leftover
assumption from this spec's original framing.

`carbide_registry`/`carbide_username`/`carbide_password` (common-vars.tf)
are now `private_registry`/`private_registry_username`/
`private_registry_password`: empty by default, no `##UPDATE##` markers, and
genuinely optional - nodes pull public images with no private registry
configured at all. `rancher-manager`'s `carbide_rancher_chart`/
`carbide_rancher_image` are now `rancher_chart_override`/
`rancher_image_override` for the same reason - a private chart/image
source is a real but generic need, not a Carbide-specific one.
`user-data.sh`'s registry-configuration functions and log messages were
reworded to match; behavior is unchanged (empty values already skipped
registry auth entirely, same as before).

Every `registry.ranchercarbide.dev` / "Carbide" mention in §6 and §9 of
this spec's original body is retained as-is - it describes the RGS-specific
reference implementation this repo was reviewed against in Phase 0, not a
requirement of this repo. Treat this entry, not those, as authoritative for
what the code actually does now.
