#!/usr/bin/env bash
# =============================================================================
# components.sh - discovery, manifest parsing, and dependency ordering
# =============================================================================
# Nothing in this file knows the name of any product. Components are found
# by globbing components/*/component.conf at runtime; adding a product means
# adding a directory, never editing this file.
#
# Manifests are parsed with awk, NOT sourced. A component.conf is data, so a
# dropped-in component cannot execute code just by being discovered.
# =============================================================================

[ -n "${DEMOCTL_COMPONENTS_SH_LOADED:-}" ] && return 0
DEMOCTL_COMPONENTS_SH_LOADED=1

# Parallel indexed arrays, one entry per discovered component. bash 3.2 has
# no associative arrays; with a handful of components a linear scan costs
# nothing and reads better than the eval indirection a map would need.
CM_NAME=() CM_DIR=() CM_DESC=() CM_ORDER=() CM_DEPS=()
CM_MANDATORY=() CM_ENABLE_VAR=() CM_KIND=() CM_LIFECYCLE=() CM_HOSTNAME_VAR=()

readonly CM_VALID_KINDS="tofu hooks tofu+hooks docs"
readonly CM_VALID_LIFECYCLES="persistent ephemeral"

# ---------------------------------------------------------------------------
# manifest_get <file> <KEY> - read one KEY=value line.
#
# Handles: leading/trailing whitespace, # comments (whole-line and trailing),
# and single or double quoted values. Everything else is taken literally.
# ---------------------------------------------------------------------------
manifest_get() {
    awk -v want="$2" '
        /^[[:space:]]*#/ { next }
        {
            eq = index($0, "=")
            if (eq == 0) next
            key = substr($0, 1, eq - 1)
            val = substr($0, eq + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key != want) next
            # A trailing comment only counts when it follows whitespace, so
            # a "#" inside a quoted value survives.
            sub(/[[:space:]]+#.*$/, "", val)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (val ~ /^".*"$/ || val ~ /^'"'"'.*'"'"'$/) {
                val = substr(val, 2, length(val) - 2)
            }
            print val
            exit
        }
    ' "$1"
}

# ---------------------------------------------------------------------------
# components_discover - populate the CM_* arrays. Idempotent.
# ---------------------------------------------------------------------------
components_discover() {
    [ -n "${CM_DISCOVERED:-}" ] && return 0

    [ -d "$COMPONENTS_DIR" ] || die "no components/ directory at ${COMPONENTS_DIR}"

    local conf dir name
    for conf in "$COMPONENTS_DIR"/*/component.conf; do
        [ -f "$conf" ] || continue
        dir=$(dirname "$conf")
        name=$(basename "$dir")

        # Directories starting with _ are scaffolding (_template), never
        # deployable. The underscore is the whole convention.
        case "$name" in _*) continue ;; esac

        _component_load "$conf" "$dir" "$name"
    done

    CM_DISCOVERED=1
    _components_validate_deps
}

_component_load() {
    local conf="$1" dir="$2" dirname="$3"
    local name desc order deps mandatory enable_var kind lifecycle hostname_var

    name=$(manifest_get "$conf" NAME)
    [ -n "$name" ] || die "${conf}: NAME is required"
    [ "$name" = "$dirname" ] || \
        die "${conf}: NAME is '${name}' but the directory is '${dirname}' - they must match"

    kind=$(manifest_get "$conf" KIND)
    [ -n "$kind" ] || kind="tofu"
    # shellcheck disable=SC2086  # a space-separated word list on purpose
    contains "$kind" $CM_VALID_KINDS || \
        die "${conf}: KIND '${kind}' is not one of: ${CM_VALID_KINDS}"

    lifecycle=$(manifest_get "$conf" LIFECYCLE)
    [ -n "$lifecycle" ] || lifecycle="ephemeral"
    # shellcheck disable=SC2086
    contains "$lifecycle" $CM_VALID_LIFECYCLES || \
        die "${conf}: LIFECYCLE '${lifecycle}' is not one of: ${CM_VALID_LIFECYCLES}"

    mandatory=$(manifest_get "$conf" MANDATORY)
    [ -n "$mandatory" ] || mandatory="false"
    case "$mandatory" in
        true|false) ;;
        *) die "${conf}: MANDATORY must be true or false, got '${mandatory}'" ;;
    esac

    order=$(manifest_get "$conf" ORDER)
    [ -n "$order" ] || order="50"
    case "$order" in
        ''|*[!0-9]*) die "${conf}: ORDER must be a whole number, got '${order}'" ;;
    esac

    desc=$(manifest_get "$conf" DESCRIPTION)
    deps=$(manifest_get "$conf" DEPENDS_ON)
    enable_var=$(manifest_get "$conf" ENABLE_VAR)
    hostname_var=$(manifest_get "$conf" HOSTNAME_VAR)

    # An optional component with no ENABLE_VAR could never be turned on.
    if [ "$mandatory" = "false" ] && [ -z "$enable_var" ]; then
        die "${conf}: optional components need ENABLE_VAR (set MANDATORY=true if it should always deploy)"
    fi

    CM_NAME+=("$name")
    CM_DIR+=("$dir")
    CM_DESC+=("$desc")
    CM_ORDER+=("$order")
    CM_DEPS+=("$deps")
    CM_MANDATORY+=("$mandatory")
    CM_ENABLE_VAR+=("$enable_var")
    CM_KIND+=("$kind")
    CM_LIFECYCLE+=("$lifecycle")
    CM_HOSTNAME_VAR+=("$hostname_var")
}

_components_validate_deps() {
    local i dep
    for i in "${!CM_NAME[@]}"; do
        for dep in ${CM_DEPS[$i]}; do
            comp_index "$dep" >/dev/null || \
                die "${CM_NAME[$i]}: DEPENDS_ON names '${dep}', which is not a component"
            [ "$dep" = "${CM_NAME[$i]}" ] && \
                die "${CM_NAME[$i]}: DEPENDS_ON lists itself"
        done
    done
}

# ---------------------------------------------------------------------------
# Field accessors
# ---------------------------------------------------------------------------

# comp_index <name> - prints the array index, or fails if unknown.
comp_index() {
    local i
    for i in "${!CM_NAME[@]}"; do
        if [ "${CM_NAME[$i]}" = "$1" ]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}

# comp_field <name> <FIELD> - FIELD is one of the manifest keys.
comp_field() {
    local idx
    idx=$(comp_index "$1") || die "unknown component: $1"
    case "$2" in
        NAME)         printf '%s' "${CM_NAME[$idx]}" ;;
        DIR)          printf '%s' "${CM_DIR[$idx]}" ;;
        DESCRIPTION)  printf '%s' "${CM_DESC[$idx]}" ;;
        ORDER)        printf '%s' "${CM_ORDER[$idx]}" ;;
        DEPENDS_ON)   printf '%s' "${CM_DEPS[$idx]}" ;;
        MANDATORY)    printf '%s' "${CM_MANDATORY[$idx]}" ;;
        ENABLE_VAR)   printf '%s' "${CM_ENABLE_VAR[$idx]}" ;;
        KIND)         printf '%s' "${CM_KIND[$idx]}" ;;
        LIFECYCLE)    printf '%s' "${CM_LIFECYCLE[$idx]}" ;;
        HOSTNAME_VAR) printf '%s' "${CM_HOSTNAME_VAR[$idx]}" ;;
        *)            die "comp_field: unknown field '$2'" ;;
    esac
}

# comp_has_tofu <name> / comp_has_hooks <name>
comp_has_tofu()  { case "$(comp_field "$1" KIND)" in *tofu*)  return 0 ;; esac; return 1; }
comp_has_hooks() { case "$(comp_field "$1" KIND)" in *hooks*) return 0 ;; esac; return 1; }

comp_is_persistent() { [ "$(comp_field "$1" LIFECYCLE)" = "persistent" ]; }
comp_is_ephemeral()  { [ "$(comp_field "$1" LIFECYCLE)" = "ephemeral" ]; }

# comp_is_enabled <name>
#
# MANDATORY means two different things depending on LIFECYCLE, and the
# distinction matters:
#   - MANDATORY + ephemeral  -> `democtl build` always deploys it.
#   - MANDATORY + persistent -> it must already EXIST before build runs;
#                               `democtl foundation up` is what creates it.
# Either way a mandatory component is never gated on an enable flag.
comp_is_enabled() {
    local name="$1" enable_var value
    [ "$(comp_field "$name" MANDATORY)" = "true" ] && return 0
    enable_var=$(comp_field "$name" ENABLE_VAR)
    value=$(get_tfvar "$enable_var")
    [ "$value" = "true" ]
}

# comp_hook <name> <hook> - path to a hook if it exists and is executable.
comp_hook() {
    local path
    path="$(comp_field "$1" DIR)/hooks/$2.sh"
    [ -x "$path" ] || return 1
    printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# Ordering
# ---------------------------------------------------------------------------
# Depth-first topological sort. DEPENDS_ON is the real constraint; ORDER is
# only a tie-breaker, applied by sorting the entry points before the walk so
# that two independent components come out in a stable, predictable order.
#
# components_order <name...> - prints the given components plus every
# component they depend on, in an order where dependencies always come first.
# Dies on a cycle, naming the path.
# ---------------------------------------------------------------------------
components_order() {
    local seeds sorted name
    _TOPO_DONE=" "
    _TOPO_OUT=""

    # Sort the requested components by ORDER, then name, before walking.
    seeds=""
    for name in "$@"; do
        seeds="${seeds}$(printf '%05d %s\n' "$(comp_field "$name" ORDER)" "$name")
"
    done
    sorted=$(printf '%s' "$seeds" | grep -v '^$' | sort | awk '{print $2}')

    for name in $sorted; do
        _topo_visit "$name" ""
    done

    # shellcheck disable=SC2086  # deliberate word splitting into one per line
    printf '%s\n' $_TOPO_OUT
}

_topo_visit() {
    local name="$1" path="$2" dep

    case "$_TOPO_DONE" in *" ${name} "*) return 0 ;; esac
    case " ${path} " in
        *" ${name} "*)
            die "dependency cycle: ${path} ${name}"
            ;;
    esac

    # Visit dependencies in ORDER, so a component with two independent
    # dependencies still produces a deterministic plan.
    local dep_sorted
    dep_sorted=$(for dep in $(comp_field "$name" DEPENDS_ON); do
        printf '%05d %s\n' "$(comp_field "$dep" ORDER)" "$dep"
    done | sort | awk '{print $2}')

    for dep in $dep_sorted; do
        _topo_visit "$dep" "${path} ${name}"
    done

    _TOPO_DONE="${_TOPO_DONE}${name} "
    _TOPO_OUT="${_TOPO_OUT} ${name}"
}

# components_all - every discovered component name, in dependency order.
components_all() {
    components_discover
    [ "${#CM_NAME[@]}" -gt 0 ] || return 0
    components_order "${CM_NAME[@]}"
}

# components_enabled <lifecycle|any> - enabled components of that tier, in
# dependency order.
components_enabled() {
    local want="${1:-any}" name out=""
    components_discover
    for name in $(components_all); do
        comp_is_enabled "$name" || continue
        if [ "$want" != "any" ] && [ "$(comp_field "$name" LIFECYCLE)" != "$want" ]; then
            continue
        fi
        out="${out} ${name}"
    done
    # shellcheck disable=SC2086
    printf '%s\n' $out
}

# ---------------------------------------------------------------------------
# components_check_deps_enabled <name...> - refuse to run when an enabled
# component depends on a disabled one, and say what to turn on.
# ---------------------------------------------------------------------------
components_check_deps_enabled() {
    local name dep problems=0
    for name in "$@"; do
        for dep in $(comp_field "$name" DEPENDS_ON); do
            comp_is_enabled "$dep" && continue
            err "${name} depends on ${dep}, which is disabled"
            hint "set $(comp_field "$dep" ENABLE_VAR) = true in ${TFVARS_FILE}"
            problems=$((problems + 1))
        done
    done
    [ "$problems" -eq 0 ]
}
