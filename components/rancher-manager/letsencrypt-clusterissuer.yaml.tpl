---
# Staging and production ClusterIssuers both exist regardless of which one
# letsencrypt-certificate.yaml.tpl actually references - cheap to have both,
# and it means flipping letsencrypt_environment doesn't need a new resource.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${letsencrypt_email}
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - dns01:
          route53:
            region: ${aws_region}
            hostedZoneID: ${route53_zone_id}
            # Ambient credentials from the instance's IAM role - no
            # access key on the node. Scoped to this zone only; see
            # foundation's node_route53 IAM policy.
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${letsencrypt_email}
    privateKeySecretRef:
      name: letsencrypt-production-account-key
    solvers:
      - dns01:
          route53:
            region: ${aws_region}
            hostedZoneID: ${route53_zone_id}
