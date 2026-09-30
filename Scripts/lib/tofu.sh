#!/usr/bin/env bash
# =============================================================================
# tofu.sh - running OpenTofu, and running component hooks
# =============================================================================
# Every component's state lives in S3 under
#   state/<environment>/<component>/terraform.tfstate
# in the bucket aws.sh manages. Components declare an empty `backend "s3" {}`
# block and democtl supplies the configuration on the command line, so no
# bucket name is ever written into a .tf file and the same checkout works
# against any environment.
#
# There is no bootstrap exception. The bucket is created by the AWS CLI
# before any tofu runs (see aws_state_bucket_ensure), so foundation uses the
# S3 backend from its very first apply exactly like everything else - no
# local state, no `init -migrate-state`, no state file hiding in a checkout.
# =============================================================================

[ -n "${DEMOCTL_TOFU_SH_LOADED:-}" ] && return 0
DEMOCTL_TOFU_SH_LOADED=1

# Minimum for `use_lockfile` (S3 native locking, no DynamoDB table needed).
# shellcheck disable=SC2034  # read by democtl preflight
readonly TOFU_MIN_VERSION="1.11.0"

tofu_version() { tofu version -json 2>/dev/null | _json_get terraform_version; }

# tofu_version_ok <have> <want> - plain numeric compare, no sort -V (macOS
# ships a sort that lacks it on older systems).
tofu_version_ok() {
    local have="$1" want="$2" h w i
    for i in 1 2 3; do
        h=$(printf '%s' "$have" | cut -d. -f"$i"); h=${h:-0}; h=${h%%[!0-9]*}; h=${h:-0}
        w=$(printf '%s' "$want" | cut -d. -f"$i"); w=${w:-0}
        [ "$h" -gt "$w" ] && return 0
        [ "$h" -lt "$w" ] && return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# tofu_init <component> - initialise with a generated S3 backend config.
#
# -reconfigure rather than -migrate-state: the backend configuration is
# derived from terraform.tfvars every run, so there is nothing to migrate,
# and -reconfigure makes switching environments in one checkout safe.
# ---------------------------------------------------------------------------
tofu_init() {
    local name="$1" dir
    dir=$(comp_field "$name" DIR)
    tfvars_load_identity

    local marker="${dir}/.terraform/democtl-backend-${ENVIRONMENT}"
    if [ -f "$marker" ] && [ "${DEMOCTL_FORCE_INIT:-}" != "1" ]; then
        return 0
    fi

    dim "  init ${name} -> s3://${STATE_BUCKET}/$(aws_state_key "$name")"
    tofu -chdir="$dir" init \
        -input=false \
        -reconfigure \
        -backend-config="bucket=${STATE_BUCKET}" \
        -backend-config="key=$(aws_state_key "$name")" \
        -backend-config="region=${AWS_REGION}" \
        -backend-config="encrypt=true" \
        -backend-config="use_lockfile=true" \
        >/dev/null || die "${name}: tofu init failed"

    : > "$marker"
}

# ---------------------------------------------------------------------------
# tofu_prepare <component> - everything that must happen before plan/apply.
# ---------------------------------------------------------------------------
tofu_prepare() {
    local name="$1"
    comp_has_tofu "$name" || return 0
    tfvars_generate "$name" >/dev/null
    tofu_init "$name"
}

tofu_plan() {
    local name="$1" dir
    dir=$(comp_field "$name" DIR)
    tofu_prepare "$name"
    tofu -chdir="$dir" plan -input=false
}

tofu_apply() {
    local name="$1" dir
    dir=$(comp_field "$name" DIR)
    tofu_prepare "$name"
    tofu -chdir="$dir" apply -input=false -auto-approve \
        || die "${name}: tofu apply failed"
}

tofu_destroy() {
    local name="$1" dir
    dir=$(comp_field "$name" DIR)
    tofu_prepare "$name"
    tofu -chdir="$dir" destroy -input=false -auto-approve \
        || die "${name}: tofu destroy failed"
}

tofu_output_all() {
    local name="$1" dir
    dir=$(comp_field "$name" DIR)
    comp_has_tofu "$name" || return 0
    tofu_init "$name"
    tofu -chdir="$dir" output
}

# ---------------------------------------------------------------------------
# component_output <component> <output> - the ONLY supported way for a hook
# to read another component's output.
#
# Hooks must not read a sibling's state file by path. Where state lives is
# democtl's business, and it has already changed once (local files in the
# reference repo, S3 here). Going through this function means a hook written
# today keeps working when that changes again.
# ---------------------------------------------------------------------------
component_output() {
    local name="$1" output="$2" dir
    dir=$(comp_field "$name" DIR) || return 1
    tofu_init "$name" >/dev/null 2>&1
    tofu -chdir="$dir" output -raw "$output" 2>/dev/null
}

# ---------------------------------------------------------------------------
# run_hook <component> <hook> [args...]
#
# Hooks run from their component's directory with a documented environment.
# A missing hook is success, not an error - every hook is optional.
# A failing hook stops the operation: a pre-destroy hook that cannot back up
# a certificate must not be followed by a destroy.
# ---------------------------------------------------------------------------
run_hook() {
    local name="$1" hook="$2"; shift 2
    local path
    path=$(comp_hook "$name" "$hook") || return 0

    dim "  hook ${name}/${hook}"
    ( _hook_env "$name" && cd "$COMPONENT_DIR" && "$path" "$@" ) \
        || die "${name}: ${hook} hook failed"
}

# run_hook_quiet <component> <hook> - for reporting hooks (urls, status)
# where a failure should not abort the command that called it.
run_hook_quiet() {
    local name="$1" hook="$2"
    local path
    path=$(comp_hook "$name" "$hook") || return 1

    ( _hook_env "$name" && cd "$COMPONENT_DIR" && "$path" ) 2>/dev/null
}

# _hook_env <component> - the documented hook environment. Called inside the
# hook's subshell, so these exports never leak back into democtl.
_hook_env() {
    tfvars_load_identity
    COMPONENT_NAME="$1"
    COMPONENT_DIR=$(comp_field "$1" DIR)
    DEMOCTL_LIB="${REPO_ROOT}/Scripts/lib"
    export COMPONENT_NAME COMPONENT_DIR DEMOCTL_LIB
    export REPO_ROOT TFVARS_FILE
    export ENVIRONMENT AWS_REGION ROOT_DOMAIN SUBDOMAIN
    export STATE_BUCKET STATE_PREFIX LABDATA_PREFIX
}
