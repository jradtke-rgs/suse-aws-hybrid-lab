#!/usr/bin/env bash
# =============================================================================
# hooks/status.sh
# =============================================================================
# Three tiers of signal, cheapest first: does Rancher answer over HTTPS?
# If not, is the instance even reachable - and if so, what does its own
# bootstrap log say? This is what turns "it's not up yet" into "it's not up
# yet, and here's why" without the operator needing to SSH in themselves
# just to check `democtl status`.
# =============================================================================
set -euo pipefail

# shellcheck source=../../../Scripts/lib/common.sh
. "${DEMOCTL_LIB}/common.sh"

host=$(component_output "$COMPONENT_NAME" rancher_hostname) || exit 0
[ -n "$host" ] || exit 0

if curl -sfk --max-time 5 "https://${host}/ping" 2>/dev/null | grep -q pong; then
    printf 'up at https://%s\n' "$host"
    exit 0
fi

ssh_cmd=$(component_output "$COMPONENT_NAME" ssh_command) || exit 0
[ -n "$ssh_cmd" ] || { printf 'not answering yet at https://%s\n' "$host"; exit 0; }

marker=$($ssh_cmd -o ConnectTimeout=5 -o BatchMode=yes \
    'sudo tail -1 /var/log/demo-bootstrap.log 2>/dev/null' 2>/dev/null) || true

if [ -n "$marker" ]; then
    printf 'not answering yet - %s\n' "$marker"
else
    printf 'not answering yet at https://%s (instance unreachable over SSH)\n' "$host"
fi
