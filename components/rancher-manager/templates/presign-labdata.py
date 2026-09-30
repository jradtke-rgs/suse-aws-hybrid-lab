#!/usr/bin/env python3
"""OpenTofu `external` data source helper: presigned GET URLs for the TLS
certificate backup this component restores from before cert-manager
reconciles (see main.tf's `data "external" "tls_backup"` and the
"Certificate persistence" section of README.md).

Presigning happens HERE - on the operator's machine, at plan/apply time -
rather than by installing an S3 client on the node. SL-Micro is immutable
and the node already needs nothing beyond `curl`; the operator's machine
already requires the AWS CLI for democtl itself, so this adds no new
dependency. A presigned URL needs no request-time credentials from whoever
fetches it, which is exactly what an unattended boot script needs.

An `external` data source's protocol: read one JSON object from stdin,
write one flat string->string JSON object to stdout. Any exception here is
treated by Terraform as a hard data-source failure (aborting the plan), so
failures to presign are caught and reported as an EMPTY url instead - user-
data.sh treats an empty or 404-ing url as "no backup exists yet", which is
the normal, expected case on a first build.
"""
import json
import subprocess
import sys


def presign(bucket, key, expires):
    try:
        result = subprocess.run(
            ["aws", "s3", "presign", f"s3://{bucket}/{key}", "--expires-in", str(expires)],
            capture_output=True, text=True, timeout=30, check=True,
        )
        return result.stdout.strip()
    except Exception:
        return ""


def main():
    query = json.load(sys.stdin)
    bucket = query["bucket"]
    prefix = query["prefix"]
    expires = int(query.get("expires_in", "3600"))

    print(json.dumps({
        "cert_url": presign(bucket, f"{prefix}/tls-rancher-ingress.yaml", expires),
        "acme_url": presign(bucket, f"{prefix}/acme-account-key.yaml", expires),
    }))


if __name__ == "__main__":
    main()
