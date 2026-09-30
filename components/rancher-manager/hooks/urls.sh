#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../Scripts/lib/common.sh
. "${DEMOCTL_LIB}/common.sh"

url=$(component_output "$COMPONENT_NAME" rancher_url) || exit 0
[ -n "$url" ] || exit 0

printf 'Rancher\t%s\n' "$url"
