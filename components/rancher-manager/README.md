# `rancher-manager` — single-node RKE2 + Rancher

**Lifecycle:** `ephemeral` · **Mandatory:** yes · **Order:** 20 · **Depends on:** `foundation`

The one product v1 exists to demo: a single EC2 instance running SL-Micro,
RKE2, and Rancher Manager, reachable over HTTPS on a real DNS name with a
real (or staging) Let's Encrypt certificate.

## What it creates

One EC2 instance, one security group (RKE2's supervisor port — everything
else comes from `foundation`'s shared groups), a Route53 A record, and
(only when `persistent_eip_names` in `terraform.tfvars` includes `"rancher"`)
an association to `foundation`'s persistent Elastic IP. No IAM — it runs as
`foundation`'s shared `<env>-node` role.

## Cost

| | |
|---|---|
| Instance | `t3.large` (2 vCPU / 8GB) — the smallest type that runs RKE2 + Rancher + cert-manager together without swapping; see the comment on `rancher_instance_type` in `variables.tf` |
| Root volume | 50GB gp3, encrypted — the stack (RKE2, containerd, Helm, cert-manager, Rancher, Carbide images) uses 15–20GB in practice; billed even while stopped |
| Public IP | ~$3.65/month either way (AWS bills every public IPv4) — see `components/foundation/README.md` |

Destroy it with `democtl destroy` when not actively demoing; `foundation`
stays up underneath at effectively zero cost.

## URLs

`democtl urls` prints `https://<hostname_rancher>.<subdomain>.<root_domain>`
once the instance is up. `hooks/post-apply.sh` waits for `/ping` to return
`pong` before `democtl build` returns — no more guessing whether a fixed
10-minute countdown was enough.

**Bootstrap password:** `admin`, set explicitly at install time (matching
the reference implementation) rather than Rancher's own random default.
Change it on first login. Fine for an ephemeral demo lab only.

## Certificate persistence

One **wildcard** certificate (`*.<subdomain>.<root_domain>`) covers this and
every future component — see the note on `enable_letsencrypt` in the root
`common-vars.tf`. Restore-before-issue is how this repo avoids Let's
Encrypt's production rate limit (5 duplicate certificates per exact name set
per week — see `SPEC.md` §9 finding #4):

- **Restore** happens inside `user-data.sh` (`restore_tls_backup`), before
  cert-manager ever sees a `Certificate` resource. It fetches over plain
  `curl` from a **presigned S3 URL** that OpenTofu generates on the
  *operator's* machine at `plan`/`apply` time
  (`templates/presign-labdata.py`) — not by installing an AWS CLI on an
  immutable SL-Micro image. A 404 (nothing backed up yet) is the normal
  case on a first build and is treated as "issue fresh," not an error.
- **Backup** happens on the *operator's* machine too, over SSH:
  `hooks/post-apply.sh` backs up right after a fresh issuance;
  `hooks/pre-destroy.sh` backs up again right before the node goes away
  (the real safety net). Both dump the Secret via `kubectl get -o yaml` and
  pipe it straight to `aws s3 cp` — no cluster-side S3 credentials needed.
- The backup path is namespaced by `letsencrypt_environment`
  (`labdata/<env>/tls/<staging|production>/...`), so flipping between
  staging and production can't restore the wrong certificate.

**Caveat:** `pre-destroy.sh` is deliberately **best-effort** — it warns
rather than blocking destroy on a failed backup. That is a relaxation of
`SPEC.md`'s stricter wording ("a non-zero exit stops the destroy"), chosen
because this lab is meant to be rebuilt often; blocking teardown on an SSH
timeout would be more friction than the rate limit it guards against.
Revisit this if `letsencrypt_environment = "production"` ever becomes the
default — `democtl preflight` already warns when it's set without a backup
present.

## Manual steps

None required for a normal build. If `carbide_username`/`carbide_password`
are set, `configure_system_default_registry` (in `user-data.sh`) points
Rancher's `system-default-registry` at Carbide automatically — **unverified
live** that a downstream node actually inherits working auth from this yet.
Fallback: Rancher UI → **Settings → Advanced Settings** (`system-default-registry`)
and **Settings → Private Registry**.

## Caveats

- **`sl_micro_version` and `ami_architecture`** (in the root `common-vars.tf`)
  pin the AMI explicitly. Without the pin, `suse-sle-micro-6-*` +
  `most_recent` sorts by publication date, not by minor version — a fresh
  6.0 release can outrank an older 6.1 one.
- **`lifecycle { ignore_changes = [ami] }`** on the instance: a new SL-Micro
  publication will never silently replace a running node on a routine
  `democtl build`. Rebuilding onto a newer image is deliberate:
  `democtl destroy --only rancher-manager && democtl build`.
- **`rke2_version` / `rancher_version` / `cert_manager_version` are coupled**
  — Rancher's chart pins a Kubernetes ceiling, cert-manager supports a
  rolling window. Run `democtl versions` before changing any of them.
- **Rancher image source is unverified**, same as the reference
  implementation: the public `rancher-stable` chart with images sourced via
  Carbide's `registries.yaml`, not a Carbide-hosted chart —
  `carbide_rancher_chart`/`carbide_rancher_image` exist to override once
  that path is confirmed.
