#!/usr/bin/env bash
# =============================================================================
# common.sh - logging, guards, and repo location
# =============================================================================
# Sourced by democtl and by every component hook. Safe to source more than
# once. Deliberately written for bash 3.2, the version macOS still ships:
# no associative arrays, no `declare -A`, no `${var,,}`. Component counts in
# this repo are small enough that a linear scan over parallel indexed arrays
# is both fast enough and easier to read than the eval tricks a hash map
# would need here.
# =============================================================================

# Guard against double-sourcing (hooks source this, and so does democtl).
[ -n "${DEMOCTL_COMMON_SH_LOADED:-}" ] && return 0
DEMOCTL_COMMON_SH_LOADED=1

# ---------------------------------------------------------------------------
# Colors - suppressed when stdout is not a terminal, so piping to a file or
# to grep produces clean text.
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[0;34m'
    C_DIM=$'\033[2m'
    C_BOLD=$'\033[1m'
    C_OFF=$'\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_DIM='' C_BOLD='' C_OFF=''
fi

# ---------------------------------------------------------------------------
# Logging. Everything except `say` goes to stderr so that command output
# stays pipeable - `democtl urls | grep rancher` should not pick up progress
# messages.
# ---------------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "${C_BLUE}$*${C_OFF}" >&2; }
ok()   { printf '%s\n' "${C_GREEN}$*${C_OFF}" >&2; }
warn() { printf '%s\n' "${C_YELLOW}WARNING: $*${C_OFF}" >&2; }
err()  { printf '%s\n' "${C_RED}ERROR: $*${C_OFF}" >&2; }
dim()  { printf '%s\n' "${C_DIM}$*${C_OFF}" >&2; }

die() { err "$@"; exit 1; }

header() {
    printf '\n%s\n' "${C_BLUE}${C_BOLD}=== $* ===${C_OFF}" >&2
}

# Print a hint under an error - the "what do I do about it" line.
hint() { printf '%s\n' "  ${C_DIM}$*${C_OFF}" >&2; }

# ---------------------------------------------------------------------------
# Repo location
# ---------------------------------------------------------------------------
# Resolves the repo root from this file's own location, so democtl and hooks
# work no matter which directory they are invoked from.
democtl_repo_root() {
    local src="${BASH_SOURCE[0]}" dir
    # Follow symlinks to this file (Scripts/lib/common.sh) before walking up.
    while [ -L "$src" ]; do
        dir=$(cd -P "$(dirname "$src")" && pwd)
        src=$(readlink "$src")
        case "$src" in
            /*) ;;
            *) src="$dir/$src" ;;
        esac
    done
    # Scripts/lib/common.sh -> repo root is two levels up.
    (cd -P "$(dirname "$src")/../.." && pwd)
}

# These are the library's public surface: democtl and every hook read them.
# shellcheck disable=SC2034  # consumed by democtl and by components/*/hooks/*.sh
REPO_ROOT="${REPO_ROOT:-$(democtl_repo_root)}"
# shellcheck disable=SC2034
COMPONENTS_DIR="${REPO_ROOT}/components"
# shellcheck disable=SC2034
TFVARS_FILE="${TFVARS_FILE:-${REPO_ROOT}/terraform.tfvars}"
# shellcheck disable=SC2034
TFVARS_EXAMPLE="${REPO_ROOT}/terraform.tfvars.example"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# have <cmd> - true if the command exists on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# require_cmd <cmd> <install hint> - die with something actionable.
require_cmd() {
    have "$1" && return 0
    err "required command not found: $1"
    [ -n "${2:-}" ] && hint "$2"
    exit 1
}

# contains <needle> <haystack...> - word-membership test.
contains() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# confirm <prompt> - yes/no, defaults to no. Honours DEMOCTL_YES=1 for
# non-interactive use, which is the ONLY way to skip a confirmation.
confirm() {
    local reply
    if [ "${DEMOCTL_YES:-}" = "1" ]; then
        dim "DEMOCTL_YES=1 - assuming yes for: $1"
        return 0
    fi
    printf '%s' "${C_YELLOW}$1 (yes/no): ${C_OFF}" >&2
    read -r reply
    [ "$reply" = "yes" ]
}

# confirm_typed <expected> <prompt> - requires typing an exact string, used
# where a plain "yes" is too easy to type by reflex (destroy, foundation down).
confirm_typed() {
    local expected="$1" prompt="$2" reply
    if [ "${DEMOCTL_YES:-}" = "1" ]; then
        dim "DEMOCTL_YES=1 - assuming '$expected' for: $prompt"
        return 0
    fi
    printf '%s' "${C_YELLOW}${prompt}${C_OFF}" >&2
    read -r reply
    [ "$reply" = "$expected" ]
}

# expand_tilde <path> - ~/x -> $HOME/x. Needed because tofu outputs and
# tfvars hold literal "~/..." strings that the shell never expands.
expand_tilde() {
    # shellcheck disable=SC2088  # matching a literal tilde is the point here
    case "$1" in
        "~/"*) printf '%s' "${HOME}/${1#\~/}" ;;
        "~")   printf '%s' "${HOME}" ;;
        *)     printf '%s' "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# The rest of the library.
#
# Sourcing common.sh is the single entry point, for democtl and for component
# hooks alike - a hook does `. "$DEMOCTL_LIB/common.sh"` and has logging,
# get_tfvar, and component_output. The primitives above are defined before
# these so the siblings can build on them.
# ---------------------------------------------------------------------------
# shellcheck source=Scripts/lib/tfvars.sh
. "${REPO_ROOT}/Scripts/lib/tfvars.sh"
# shellcheck source=Scripts/lib/components.sh
. "${REPO_ROOT}/Scripts/lib/components.sh"
# shellcheck source=Scripts/lib/aws.sh
. "${REPO_ROOT}/Scripts/lib/aws.sh"
# shellcheck source=Scripts/lib/tofu.sh
. "${REPO_ROOT}/Scripts/lib/tofu.sh"
