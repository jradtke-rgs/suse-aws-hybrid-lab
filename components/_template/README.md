# `_template` — copy-me skeleton for a new component

This directory is **never deployed**. Discovery skips any directory whose
name starts with `_`, and the manifest ships `KIND=docs` as a second lock so
that an unfinished copy cannot create anything either.

```bash
Scripts/democtl new-component harbor
```

That copies this directory to `components/harbor`, substitutes the name
everywhere, creates the `common-vars.tf` symlink, and flips `KIND=docs` to
`KIND=tofu`.

## The contract

A component is a directory with a manifest. `democtl` finds it by globbing
`components/*/component.conf` at runtime — there is no list of components
anywhere in `Scripts/`, and adding one requires editing nothing outside your
own directory except `terraform.tfvars`.

| File | Required | What it is |
|---|---|---|
| `component.conf` | **yes** | The manifest. Parsed as data, never sourced. |
| `README.md` | **yes** | Purpose, cost, URLs, manual steps, caveats. |
| `main.tf` `variables.tf` `outputs.tf` | if `KIND` has `tofu` | An OpenTofu root module. |
| `common-vars.tf` | if `tofu` | **Symlink** to `../../common-vars.tf`. Never a copy. |
| `hooks/*.sh` | optional | Lifecycle scripts. Must be executable to run. |
| `templates/` | optional | Inputs to `templatefile()` — user-data, manifests, Helm values. |

## Checklist for a new component

1. **`component.conf`** — set `DESCRIPTION`, `ORDER`, `DEPENDS_ON`,
   `LIFECYCLE`, and `HOSTNAME_VAR` if it gets a DNS name.
2. **`variables.tf`** — declare everything this component owns. Anything
   shared already lives in `common-vars.tf`; do not redeclare it.
3. **`terraform.tfvars.example`** — add a block for this component at the
   repo root, including `enable_<name>`. `democtl preflight` warns when your
   real `terraform.tfvars` is missing something the example defines, so
   skipping this step is how the next person gets a confusing failure.
4. **`main.tf`** — read dependencies through `terraform_remote_state`, only
   for components named in `DEPENDS_ON`.
5. **`hooks/`** — rename the `.sh.example` files you need and `chmod +x`
   them. A hook that is not executable is ignored.
6. **`README.md`** — replace this file. Say what it costs to run.
7. **Verify** without creating anything:
   ```bash
   Scripts/democtl list                 # is it discovered, in the right order?
   Scripts/democtl build --dry-run      # where does it land in the plan?
   tofu -chdir=components/<name> validate
   ```

## Things worth knowing before you write the OpenTofu

- **Ordering.** `DEPENDS_ON` is the real constraint and `ORDER` only breaks
  ties between independent components. Destroy runs the reverse order, and
  `democtl` refuses to destroy a component something deployed still depends
  on.
- **Two tiers.** `LIFECYCLE=ephemeral` means `democtl build` and
  `democtl destroy` own it. `LIFECYCLE=persistent` means only
  `democtl foundation` touches it. Put anything billed by the hour in the
  ephemeral tier; the point of the split is that tearing the lab down leaves
  nothing running.
- **Tags are not decoration.** `democtl orphans` finds strays by the
  `Environment` tag. An untagged resource is one no cleanup command can see,
  and interrupted destroys do leave strays.
- **State.** Yours lives at
  `s3://<bucket>/state/<environment>/<component>/terraform.tfstate`.
  `democtl` configures the backend on the command line; your `backend "s3" {}`
  block stays empty.
- **Reading a sibling.** From OpenTofu use `terraform_remote_state`. From a
  hook use `component_output <component> <output>`. Never open another
  component's state file by path — where state lives has already changed
  once and will change again.
- **New AMI publications replace instances.** An `aws_ami` data source with
  `most_recent = true` moves whenever the vendor publishes, which turns a
  no-op `build` into a node replacement. Use
  `lifecycle { ignore_changes = [ami] }` and make rebuilding deliberate.
