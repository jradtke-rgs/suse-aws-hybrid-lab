#!/usr/bin/env bash
# =============================================================================
# tfvars.sh - reading the root terraform.tfvars, and feeding components from it
# =============================================================================
# One gitignored terraform.tfvars at the repo root holds settings for every
# component. Two things happen to it:
#
#   1. democtl reads individual scalars out of it (get_tfvar) for its own
#      decisions - which components are enabled, which region to talk to.
#   2. Before running tofu, democtl writes a per-component democtl.auto.tfvars
#      holding only the variables that component declares. That is what
#      keeps "Value for undeclared variable" warnings out of the output.
#      See tfvars_filter.py for why that matters.
# =============================================================================

[ -n "${DEMOCTL_TFVARS_SH_LOADED:-}" ] && return 0
DEMOCTL_TFVARS_SH_LOADED=1

readonly TFVARS_FILTER="${REPO_ROOT}/Scripts/lib/tfvars_filter.py"
readonly GENERATED_TFVARS="democtl.auto.tfvars"

# ---------------------------------------------------------------------------
# get_tfvar <key> [default]
#
# Reads one scalar out of terraform.tfvars. Handles `key = "value"`,
# `key = true`, `key = 42`, and trailing comments. Lists and maps are not
# handled - nothing in democtl needs one, and OpenTofu reads the real file
# for those.
# ---------------------------------------------------------------------------
get_tfvar() {
    local key="$1" default="${2:-}" value

    # shellcheck disable=SC2153  # TFVARS_FILE is set by common.sh
    if [ ! -f "$TFVARS_FILE" ]; then
        printf '%s' "$default"
        return 0
    fi

    value=$(awk -v want="$key" '
        /^[[:space:]]*#/ { next }
        {
            eq = index($0, "=")
            if (eq == 0) next
            k = substr($0, 1, eq - 1)
            v = substr($0, eq + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            if (k != want) next
            sub(/[[:space:]]+#.*$/, "", v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            if (v ~ /^".*"$/) { v = substr(v, 2, length(v) - 2) }
            print v
            exit
        }
    ' "$TFVARS_FILE")

    [ -n "$value" ] || value="$default"
    printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# Derived lab identity. These are read once and reused; every command needs
# them and re-parsing the file per call adds up in loops.
# ---------------------------------------------------------------------------
tfvars_load_identity() {
    [ -n "${DEMOCTL_IDENTITY_LOADED:-}" ] && return 0

    ENVIRONMENT=$(get_tfvar environment "suse-aws-hybrid-lab")
    AWS_REGION=$(get_tfvar aws_region "us-east-2")
    ROOT_DOMAIN=$(get_tfvar root_domain)
    SUBDOMAIN=$(get_tfvar subdomain "$ENVIRONMENT")

    # One bucket, two prefixes - state/ and labdata/. A single bucket is one
    # thing to create, one thing to empty, and one lifecycle policy. The
    # bucket itself is NOT managed by OpenTofu: like the Route53 zone it is
    # pre-existing infrastructure this repo reads and writes but never
    # destroys, which also avoids the knot of a component's state living
    # inside a bucket that same component manages.
    STATE_BUCKET=$(get_tfvar state_bucket "$ENVIRONMENT")
    STATE_PREFIX="state/${ENVIRONMENT}"
    LABDATA_PREFIX="labdata/${ENVIRONMENT}"

    export ENVIRONMENT AWS_REGION ROOT_DOMAIN SUBDOMAIN
    export STATE_BUCKET STATE_PREFIX LABDATA_PREFIX
    DEMOCTL_IDENTITY_LOADED=1
}

# fqdn_for <hostname> - <hostname>.<subdomain>.<root_domain>
fqdn_for() {
    tfvars_load_identity
    [ -n "$ROOT_DOMAIN" ] || return 1
    printf '%s.%s.%s' "$1" "$SUBDOMAIN" "$ROOT_DOMAIN"
}

# ---------------------------------------------------------------------------
# tfvars_exists - just the file-presence check, no placeholder scan.
#
# Split out from tfvars_require so a command that only needs foundation's
# settings (which never include a Carbide password or an LE email) is not
# blocked on placeholders it will never read. See _tfvars_placeholders below
# for the scoped version those commands use instead.
# ---------------------------------------------------------------------------
tfvars_exists() {
    if [ ! -f "$TFVARS_FILE" ]; then
        err "terraform.tfvars not found at ${TFVARS_FILE}"
        hint "cp terraform.tfvars.example terraform.tfvars   # then fill it in"
        return 1
    fi
    return 0
}

# _tfvars_placeholders <file> - ##UPDATE## markers on actual assignment
# lines only. Deliberately excludes prose (the instructions at the top of
# terraform.tfvars.example mention the literal marker while explaining what
# it means, which is not itself a placeholder to fill in).
_tfvars_placeholders() {
    grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*=.*##UPDATE##' "$1" || true
}

# ---------------------------------------------------------------------------
# tfvars_require - terraform.tfvars must exist AND have every placeholder in
# the WHOLE file filled in. Used before a full build, where every setting is
# in play. A single component that only needs some of those settings should
# use tfvars_exists plus its own generated file - see tofu_prepare.
# ---------------------------------------------------------------------------
tfvars_require() {
    tfvars_exists || return 1

    local placeholders
    placeholders=$(_tfvars_placeholders "$TFVARS_FILE")
    if [ -n "$placeholders" ]; then
        err "terraform.tfvars still has ##UPDATE## placeholders:"
        printf '%s\n' "$placeholders" | sed 's/^/    /' >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# tfvars_check_drift - warn about keys in the example that the real file is
# missing. This is how you find out a newly added component needs settings
# you have not supplied yet, instead of finding out from a tofu error.
# ---------------------------------------------------------------------------
tfvars_check_drift() {
    [ -f "$TFVARS_EXAMPLE" ] || return 0
    [ -f "$TFVARS_FILE" ] || return 0

    local missing key
    missing=""
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS_FILE" || missing="${missing} ${key}"
    done < <(_tfvars_keys "$TFVARS_EXAMPLE")

    if [ -n "$missing" ]; then
        warn "terraform.tfvars.example defines settings your terraform.tfvars does not:"
        local k
        for k in $missing; do printf '    %s\n' "$k" >&2; done
        hint "each falls back to its variable default - add them if the default is wrong for you"
    fi
    return 0
}

_tfvars_keys() {
    awk '
        /^[[:space:]]*#/ { next }
        {
            eq = index($0, "=")
            if (eq == 0) next
            k = substr($0, 1, eq - 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            if (k ~ /^[A-Za-z_][A-Za-z0-9_-]*$/) print k
        }
    ' "$1" | sort -u
}

# ---------------------------------------------------------------------------
# tfvars_generate <component> - write <component dir>/democtl.auto.tfvars.
#
# Injected values are facts democtl computes rather than settings the user
# writes: which bucket state lives in, which prefix lab data uses. They
# override anything with the same name in terraform.tfvars.
# ---------------------------------------------------------------------------
tfvars_generate() {
    local name="$1" dir tf_args out
    dir=$(comp_field "$name" DIR)
    out="${dir}/${GENERATED_TFVARS}"

    tfvars_load_identity

    tf_args=()
    local f
    for f in "$dir"/*.tf; do
        [ -f "$f" ] || continue
        tf_args+=(--tf-file "$f")
    done
    [ "${#tf_args[@]}" -gt 0 ] || die "${name}: KIND includes tofu but the directory has no .tf files"

    python3 "$TFVARS_FILTER" \
        --tfvars "$TFVARS_FILE" \
        --component "$name" \
        "${tf_args[@]}" \
        --set "state_bucket=${STATE_BUCKET}" \
        --set "labdata_bucket=${STATE_BUCKET}" \
        --set "subdomain=${SUBDOMAIN}" \
        --out "$out" \
        2>/dev/null \
        || die "${name}: failed to generate ${GENERATED_TFVARS}"

    printf '%s' "$out"
}
