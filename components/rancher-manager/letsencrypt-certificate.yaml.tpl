---
# One WILDCARD certificate for the whole lab, not one per hostname - see the
# note on enable_letsencrypt in common-vars.tf. secretName matches what
# Rancher's chart expects at ingress.tls.source=secret.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-tls
  namespace: cattle-system
spec:
  secretName: tls-rancher-ingress
  issuerRef:
    name: letsencrypt-${letsencrypt_environment}
    kind: ClusterIssuer
  commonName: ${wildcard_fqdn}
  dnsNames:
    - ${wildcard_fqdn}
