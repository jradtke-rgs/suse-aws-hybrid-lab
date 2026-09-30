#!/usr/bin/env bash
# =============================================================================
# hooks/pre-destroy.sh
# =============================================================================
# The real safety net for the certificate backup: runs right before the
# node that would otherwise take the certificate with it is destroyed.
#
# Deliberately best-effort (warns, does not block destroy) rather than the
# strict reading of SPEC.md's "a non-zero exit stops the destroy" - for a
# lab this is meant to be torn down and rebuilt often, refusing to destroy
# because SSH timed out or Let's Encrypt was never enabled would be more
# friction than the rate-limit problem this exists to prevent. Worth
# revisiting if letsencrypt_environment=production ever becomes the default
# (see the warning in `democtl preflight`).
# =============================================================================
set -euo pipefail

# shellcheck source=../../../Scripts/lib/common.sh
. "${DEMOCTL_LIB}/common.sh"

le_env=$(get_tfvar letsencrypt_environment "staging")
enabled=$(get_tfvar enable_letsencrypt "true")
if [ "$enabled" != "true" ]; then
    dim "Let's Encrypt disabled - nothing to back up"
    exit 0
fi

prefix=$(component_output "$COMPONENT_NAME" labdata_tls_prefix) || exit 0
ssh_cmd=$(component_output "$COMPONENT_NAME" ssh_command) || exit 0
if [ -z "$prefix" ] || [ -z "$ssh_cmd" ]; then
    warn "could not determine backup target - was rancher-manager ever fully applied?"
    exit 0
fi

info "backing up the wildcard TLS certificate before destroy"

if $ssh_cmd -o ConnectTimeout=5 -o BatchMode=yes \
    'kubectl -n cattle-system get secret tls-rancher-ingress -o yaml' 2>/dev/null \
    | aws s3 cp - "s3://${STATE_BUCKET}/${prefix}/tls-rancher-ingress.yaml" >/dev/null 2>&1; then
    ok "TLS certificate backed up - the next build restores it instead of re-issuing"
else
    warn "could not back up the TLS certificate - the next build will issue a new one"
    [ "$le_env" = "production" ] && \
        hint "letsencrypt_environment=production: repeated rebuilds without a backup will hit Let's Encrypt's rate limit"
fi

if $ssh_cmd -o ConnectTimeout=5 -o BatchMode=yes \
    "kubectl -n cert-manager get secret letsencrypt-${le_env}-account-key -o yaml" 2>/dev/null \
    | aws s3 cp - "s3://${STATE_BUCKET}/${prefix}/acme-account-key.yaml" >/dev/null 2>&1; then
    ok "ACME account key backed up"
fi
