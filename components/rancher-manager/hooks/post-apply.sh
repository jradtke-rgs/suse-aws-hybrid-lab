#!/usr/bin/env bash
# =============================================================================
# hooks/post-apply.sh
# =============================================================================
# 1. Waits for Rancher's /ping endpoint to return "pong" - replacing the
#    reference implementation's fixed 600s countdown with an actual check,
#    and failing fast with the real bootstrap log location if it never
#    comes up instead of a silent timeout.
# 2. Backs the wildcard TLS certificate up to the lab-data bucket right
#    after a fresh issuance - the other half of the restore-before-issue
#    pattern in user-data.sh's restore_tls_backup(). Best-effort: a backup
#    failure here is a WARNING, not a failed build, because the real
#    safety net is pre-destroy.sh, which runs right before the certificate
#    would actually be needed again.
# =============================================================================
set -euo pipefail

# shellcheck source=../../../Scripts/lib/common.sh
. "${DEMOCTL_LIB}/common.sh"

host=$(component_output "$COMPONENT_NAME" rancher_hostname)
info "waiting for https://${host}/ping (up to 10 minutes)"

deadline=$(( $(date +%s) + 600 ))
until curl -sfk --max-time 5 "https://${host}/ping" 2>/dev/null | grep -q pong; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        err "${host} did not answer within 10 minutes"
        hint "democtl ssh rancher-manager, then: sudo tail -f /var/log/demo-bootstrap.log"
        exit 1
    fi
    sleep 15
done
ok "${host} is up"

le_env=$(get_tfvar letsencrypt_environment "staging")
[ "$le_env" != "" ] || exit 0

prefix=$(component_output "$COMPONENT_NAME" labdata_tls_prefix) || exit 0
ssh_cmd=$(component_output "$COMPONENT_NAME" ssh_command) || exit 0
[ -n "$prefix" ] && [ -n "$ssh_cmd" ] || exit 0

info "backing up the wildcard TLS certificate to s3://${STATE_BUCKET}/${prefix}/"

if $ssh_cmd -o ConnectTimeout=5 -o BatchMode=yes \
    'kubectl -n cattle-system get secret tls-rancher-ingress -o yaml' 2>/dev/null \
    | aws s3 cp - "s3://${STATE_BUCKET}/${prefix}/tls-rancher-ingress.yaml" >/dev/null 2>&1; then
    ok "TLS certificate backed up"
else
    warn "could not back up the TLS certificate (cert-manager may not have issued one yet)"
    hint "this is not fatal here - pre-destroy.sh backs it up again before teardown"
fi

if $ssh_cmd -o ConnectTimeout=5 -o BatchMode=yes \
    "kubectl -n cert-manager get secret letsencrypt-${le_env}-account-key -o yaml" 2>/dev/null \
    | aws s3 cp - "s3://${STATE_BUCKET}/${prefix}/acme-account-key.yaml" >/dev/null 2>&1; then
    ok "ACME account key backed up"
fi
