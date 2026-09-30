#!/bin/bash
# =============================================================================
# user-data.sh - rancher-manager bootstrap
# =============================================================================
# Runs once, unattended, as root, via cloud-init. Broken into named
# functions per SPEC.md so the sequence reads top-to-bottom; every function
# logs its own start to /var/log/demo-bootstrap.log with a timestamp, and
# the whole script ends with BOOTSTRAP COMPLETE or BOOTSTRAP FAILED at
# <step> - `democtl ssh rancher-manager` then `sudo tail` that file, or
# hooks/status.sh reads the marker remotely.
# =============================================================================
set -e

# SL-Micro's "/" is a read-only btrfs snapshot; cloud-init runs this script
# with $HOME unset, so Helm (and anything else XDG-aware) resolves its
# config/cache dirs as RELATIVE paths against cwd "/" and fails with
# "mkdir .config: read-only file system" right at `helm repo add`. /root is
# its own writable subvolume. Confirmed live in the reference implementation
# this repo is built from - see SPEC.md Decision Log.
export HOME=/root
cd /root

LOG=/var/log/demo-bootstrap.log
touch "$LOG"

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"
}

CURRENT_STEP="startup"
step() {
    CURRENT_STEP="$1"
    log "==> ${1}"
}

on_error() {
    log "BOOTSTRAP FAILED at $CURRENT_STEP"
}
trap on_error ERR

log "suse-aws-hybrid-lab bootstrap starting (${environment}/rancher-manager)"
log "host: $(hostname)   whoami: $(whoami)"

PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

# =============================================================================
configure_registries() {
    step "Configuring Carbide registry auth for RKE2's containerd"
    mkdir -p /etc/rancher/rke2
%{ if carbide_username != "" && carbide_password != "" ~}
    cat <<REGISTRIES_EOF > /etc/rancher/rke2/registries.yaml
configs:
  "${carbide_registry}":
    auth:
      username: "${carbide_username}"
      password: "${carbide_password}"
REGISTRIES_EOF
    chmod 600 /etc/rancher/rke2/registries.yaml
%{ else ~}
    log "no Carbide credentials supplied - RKE2 will only pull public images"
%{ endif ~}
}

# =============================================================================
install_rke2() {
    step "Installing RKE2 ${rke2_version}"
    export INSTALL_RKE2_VERSION="${rke2_version}"
    curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="server" sh -

    cat <<CONFIG_EOF > /etc/rancher/rke2/config.yaml
tls-san:
  - "${hostname}"
  - "${wildcard_fqdn}"
  - "$PUBLIC_IP"
  - "$PRIVATE_IP"
write-kubeconfig-mode: "0644"
CONFIG_EOF

    systemctl enable rke2-server.service
    systemctl start rke2-server.service

    log "waiting for the rke2-server service to be active"
    until systemctl is-active --quiet rke2-server; do sleep 5; done

    mkdir -p /root/.kube /home/ec2-user/.kube
    ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
    ln -sf /var/lib/rancher/rke2/bin/crictl /usr/local/bin/crictl
    export PATH=$PATH:/var/lib/rancher/rke2/bin
    export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

    cp /etc/rancher/rke2/rke2.yaml /root/.kube/config
    chmod 600 /root/.kube/config
    cp /etc/rancher/rke2/rke2.yaml /home/ec2-user/.kube/config
    chown -R ec2-user /home/ec2-user/.kube

    cat <<'BASHRC_EOF' | tee -a /root/.bashrc /home/ec2-user/.bashrc >/dev/null
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
alias kge='clear; kubectl get events --sort-by=.lastTimestamp'
alias kgea='clear; kubectl get events -A --sort-by=.lastTimestamp'
BASHRC_EOF

    log "waiting for the RKE2 API server to respond"
    until kubectl get nodes >/dev/null 2>&1; do sleep 5; done

    log "waiting for the node to be Ready"
    until kubectl wait --for=condition=Ready nodes --all --timeout=10s >/dev/null 2>&1; do sleep 5; done

    log "waiting for CoreDNS"
    until kubectl get deployment -n kube-system rke2-coredns-rke2-coredns >/dev/null 2>&1; do sleep 5; done
    kubectl wait --for=condition=available --timeout=300s deployment/rke2-coredns-rke2-coredns -n kube-system

    log "RKE2 is ready"
}

# =============================================================================
install_helm() {
    step "Installing Helm"
    curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

# =============================================================================
install_cert_manager() {
    step "Installing cert-manager ${cert_manager_version}"
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/v${cert_manager_version}/cert-manager.crds.yaml"

    helm repo add jetstack https://charts.jetstack.io >/dev/null
    helm repo update >/dev/null

    kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --version "v${cert_manager_version}" \
        --wait

    kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s
}

# =============================================================================
# Restores the wildcard TLS Secret and the ACME account-key Secret from the
# lab-data bucket, BEFORE the Certificate resource is created - so
# cert-manager finds an already-valid Secret on reconcile instead of
# treating this as a fresh issuance. This is the fix for Let's Encrypt's
# duplicate-certificate rate limit (5/name/week) that made every prior
# rebuild in the reference implementation burn part of that budget.
#
# The restore fetches via plain curl against a presigned S3 URL generated
# by OpenTofu on the OPERATOR's machine (templates/presign-labdata.py) -
# nothing here needs AWS credentials or an S3 client. A 404 (no backup
# exists - the normal case on a first build) is treated as "nothing to
# restore", not an error: `curl -f` fails quietly and this function moves
# on to let cert-manager issue fresh.
# =============================================================================
restore_tls_backup() {
    step "Restoring TLS backup, if one exists"
    kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null

%{ if tls_restore_cert_url != "" ~}
    if curl -sf "${tls_restore_cert_url}" -o /tmp/tls-rancher-ingress.yaml; then
        kubectl apply -f /tmp/tls-rancher-ingress.yaml
        log "restored the wildcard TLS secret from the lab-data backup"
    else
        log "no TLS backup found - cert-manager will issue a new certificate"
    fi
%{ else ~}
    log "Let's Encrypt disabled or newly configured - nothing to restore"
%{ endif ~}

%{ if tls_restore_acme_url != "" ~}
    if curl -sf "${tls_restore_acme_url}" -o /tmp/acme-account-key.yaml; then
        kubectl apply -f /tmp/acme-account-key.yaml
        log "restored the ACME account key from the lab-data backup"
    fi
%{ endif ~}
}

# =============================================================================
configure_letsencrypt() {
%{ if enable_letsencrypt ~}
    step "Configuring Let's Encrypt (${letsencrypt_environment})"

    cat <<'ISSUER_EOF' | kubectl apply -f -
${letsencrypt_clusterissuer}
ISSUER_EOF

    for issuer in letsencrypt-staging letsencrypt-production; do
        timeout=60
        while [ "$timeout" -gt 0 ]; do
            status=$(kubectl get clusterissuer "$issuer" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
            [ "$status" = "True" ] && break
            sleep 2
            timeout=$((timeout - 1))
        done
    done

    log "requesting the wildcard certificate (letsencrypt-${letsencrypt_environment})"
    cat <<'CERT_EOF' | kubectl apply -f -
${letsencrypt_certificate}
CERT_EOF

    timeout=300
    while [ "$timeout" -gt 0 ]; do
        ready=$(kubectl get certificate wildcard-tls -n cattle-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        [ "$ready" = "True" ] && { log "wildcard certificate is Ready"; break; }
        sleep 5
        timeout=$((timeout - 5))
    done
%{ else ~}
    step "Let's Encrypt disabled - Rancher will use a self-signed certificate"
%{ endif ~}
}

# =============================================================================
install_rancher() {
    step "Installing Rancher ${rancher_version}"
    kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null

%{ if carbide_rancher_chart != "" ~}
    log "installing from Carbide-hosted chart: ${carbide_rancher_chart}"
    helm install rancher "${carbide_rancher_chart}" \
        --namespace cattle-system \
        --set hostname="${hostname}" \
        --set replicas=1 \
        --set bootstrapPassword=admin \
%{ if enable_letsencrypt ~}
        --set ingress.tls.source=secret \
%{ endif ~}
        --wait --timeout 15m
%{ else ~}
    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable >/dev/null
    helm repo update >/dev/null

    helm install rancher rancher-stable/rancher \
        --namespace cattle-system \
        --set hostname="${hostname}" \
        --set replicas=1 \
        --set bootstrapPassword=admin \
%{ if enable_letsencrypt ~}
        --set ingress.tls.source=secret \
%{ endif ~}
%{ if carbide_rancher_image != "" ~}
        --set rancherImage="${carbide_rancher_image}" \
%{ endif ~}
        --version "${rancher_version}" \
        --wait --timeout 15m
%{ endif ~}

    log "waiting for the Rancher deployment to become available"
    kubectl -n cattle-system wait --for=condition=available --timeout=600s deployment/rancher
    kubectl -n cattle-system wait --for=condition=ready --timeout=600s pod -l app=rancher
}

# =============================================================================
# Non-fatal by design: this is a convenience that saves manually pointing
# Rancher at Carbide after the fact (Settings -> Advanced Settings), not a
# correctness requirement for the install that already succeeded above.
# Unverified live that a downstream node actually inherits working auth from
# this - see README's "Carbide as system-default-registry" caveat.
# =============================================================================
configure_system_default_registry() {
%{ if carbide_username != "" && carbide_password != "" ~}
    step "Configuring Carbide as Rancher's system-default-registry"

    ready=false
    for _ in $(seq 1 30); do
        kubectl get settings.management.cattle.io system-default-registry >/dev/null 2>&1 && { ready=true; break; }
        sleep 5
    done

    if [ "$ready" = "true" ]; then
        if kubectl patch settings.management.cattle.io system-default-registry \
            --type=merge -p "{\"value\":\"${carbide_registry}\"}"; then
            log "system-default-registry set to ${carbide_registry}"
        else
            log "WARNING: failed to patch system-default-registry - set it manually (Settings -> Advanced Settings)"
        fi

        if kubectl create secret docker-registry cattle-private-registry \
            --namespace cattle-system \
            --docker-server="${carbide_registry}" \
            --docker-username="${carbide_username}" \
            --docker-password="${carbide_password}" \
            --dry-run=client -o yaml | kubectl apply -f -; then
            log "cattle-private-registry credentials secret created"
        else
            log "WARNING: failed to create the Private Registry secret - set it manually (Settings -> Private Registry)"
        fi
    else
        log "WARNING: system-default-registry Setting never appeared - configure it manually"
    fi
%{ else ~}
    step "No Carbide credentials supplied - skipping system-default-registry"
%{ endif ~}
}

# =============================================================================
configure_registries
install_rke2
install_helm
install_cert_manager
restore_tls_backup
configure_letsencrypt
install_rancher
configure_system_default_registry

log "Rancher reachable at: https://${hostname}"
log "bootstrap password: admin (change on first login)"
log "BOOTSTRAP COMPLETE"
