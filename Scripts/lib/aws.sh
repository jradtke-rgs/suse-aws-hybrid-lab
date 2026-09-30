#!/usr/bin/env bash
# =============================================================================
# aws.sh - talking to AWS outside of OpenTofu
# =============================================================================
# Credentials come from the standard AWS CLI chain (AWS_PROFILE, SSO,
# environment variables, instance role). This repo never stores, prompts
# for, or writes an AWS key.
# =============================================================================

[ -n "${DEMOCTL_AWS_SH_LOADED:-}" ] && return 0
DEMOCTL_AWS_SH_LOADED=1

# ---------------------------------------------------------------------------
# aws_identity - who are we, and in which account?
#
# Printed before anything that creates or destroys. The failure this
# prevents is mundane and expensive: running `destroy` against the wrong
# profile because a shell three tabs ago exported a different AWS_PROFILE.
# ---------------------------------------------------------------------------
aws_identity() {
    [ -n "${AWS_ACCOUNT_ID:-}" ] && return 0

    local json
    if ! json=$(aws sts get-caller-identity --output json 2>&1); then
        err "AWS credentials are not working"
        printf '%s\n' "$json" | sed 's/^/    /' >&2
        hint "check AWS_PROFILE, or run: aws sso login"
        return 1
    fi

    AWS_ACCOUNT_ID=$(printf '%s' "$json" | _json_get Account)
    AWS_CALLER_ARN=$(printf '%s' "$json" | _json_get Arn)
    export AWS_ACCOUNT_ID AWS_CALLER_ARN
    return 0
}

aws_show_identity() {
    aws_identity || return 1
    tfvars_load_identity
    dim "account ${AWS_ACCOUNT_ID}  region ${AWS_REGION}  ${AWS_CALLER_ARN##*/}${AWS_PROFILE:+  profile ${AWS_PROFILE}}"
}

# _json_get <key> - pull a top-level string out of JSON on stdin. Uses jq
# when present and python3 otherwise, so neither is a hard requirement for
# the common path.
_json_get() {
    if have jq; then
        jq -r --arg k "$1" '.[$k] // empty'
    else
        python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('$1', ''))
except Exception:
    pass
"
    fi
}

# ---------------------------------------------------------------------------
# aws_check_route53 - the public hosted zone must already exist.
#
# This repo references the zone and never creates or destroys it: the zone
# is the one piece of the lab that outlives everything, and deleting it
# would break anything else delegating into the domain. Read access is
# treated as a proxy for write access - if the zone is visible under these
# credentials we assume they can also change records, rather than probing
# with a throwaway record or simulating IAM policy.
# ---------------------------------------------------------------------------
aws_check_route53() {
    tfvars_load_identity

    if [ -z "$ROOT_DOMAIN" ]; then
        err "root_domain is not set in terraform.tfvars"
        hint "the lab needs a real DNS name - Let's Encrypt cannot issue for an IP"
        return 1
    fi

    local zone="${SUBDOMAIN}.${ROOT_DOMAIN}" zone_id private
    zone_id=$(get_tfvar route53_zone_id)
    zone_id="${zone_id#/hostedzone/}"

    if [ -n "$zone_id" ]; then
        if ! private=$(aws route53 get-hosted-zone --id "$zone_id" \
            --query 'HostedZone.Config.PrivateZone' --output text 2>&1); then
            err "cannot read Route53 hosted zone ${zone_id}"
            printf '%s\n' "$private" | sed 's/^/    /' >&2
            return 1
        fi
    else
        private=$(aws route53 list-hosted-zones-by-name --dns-name "$zone" \
            --query "HostedZones[?Name=='${zone}.'].Config.PrivateZone | [0]" \
            --output text 2>/dev/null)
        if [ -z "$private" ] || [ "$private" = "None" ]; then
            err "no hosted zone for ${zone} in account ${AWS_ACCOUNT_ID:-?}"
            hint "create the zone and delegate it from ${ROOT_DOMAIN}, or set route53_zone_id"
            return 1
        fi
        zone_id=$(aws route53 list-hosted-zones-by-name --dns-name "$zone" \
            --query "HostedZones[?Name=='${zone}.'].Id | [0]" --output text 2>/dev/null)
        zone_id="${zone_id#/hostedzone/}"
    fi

    if [ "$private" = "True" ]; then
        err "the hosted zone for ${zone} is PRIVATE - Let's Encrypt cannot validate against it"
        return 1
    fi

    ROUTE53_ZONE_ID="$zone_id"
    export ROUTE53_ZONE_ID
    ok "Route53 public zone ${zone} (${zone_id})"
    return 0
}

# ---------------------------------------------------------------------------
# State bucket
# ---------------------------------------------------------------------------
# The bucket is created and configured with the AWS CLI, not OpenTofu, and
# is never deleted by this repo. That is deliberate:
#
#   - It removes a bootstrap knot. foundation's own state lives in this
#     bucket, so a component that managed the bucket would be managing the
#     thing holding its own state.
#   - It matches how the Route53 zone is already treated: pre-existing
#     infrastructure the lab reads and writes, on a different lifecycle from
#     anything `democtl destroy` touches.
#   - A `destroy` typo can never delete your state history.
#
# Everything about the call below is idempotent, so running it again on an
# existing bucket just re-asserts the settings.
# ---------------------------------------------------------------------------
aws_state_bucket_exists() {
    tfvars_load_identity
    aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1
}

aws_state_bucket_ensure() {
    tfvars_load_identity

    if aws_state_bucket_exists; then
        info "state bucket s3://${STATE_BUCKET} already exists"
    else
        info "creating state bucket s3://${STATE_BUCKET} in ${AWS_REGION}"
        # us-east-1 is the one region that rejects a LocationConstraint.
        if [ "$AWS_REGION" = "us-east-1" ]; then
            aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$AWS_REGION" >/dev/null \
                || die "could not create s3://${STATE_BUCKET} (bucket names are globally unique - try setting state_bucket in terraform.tfvars)"
        else
            aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$AWS_REGION" \
                --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null \
                || die "could not create s3://${STATE_BUCKET} (bucket names are globally unique - try setting state_bucket in terraform.tfvars)"
        fi
    fi

    # Versioning is what makes a bad apply recoverable: every state write
    # keeps the previous object version.
    aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" \
        --versioning-configuration Status=Enabled >/dev/null \
        || warn "could not enable versioning on s3://${STATE_BUCKET}"

    aws s3api put-bucket-encryption --bucket "$STATE_BUCKET" \
        --server-side-encryption-configuration \
        '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}' >/dev/null \
        || warn "could not set default encryption on s3://${STATE_BUCKET}"

    aws s3api put-public-access-block --bucket "$STATE_BUCKET" \
        --public-access-block-configuration \
        'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' >/dev/null \
        || warn "could not block public access on s3://${STATE_BUCKET}"

    # Versioning without expiry grows forever. A few months of history is far
    # more than a lab needs and keeps the bill at pennies.
    local retention
    retention=$(get_tfvar labdata_retention_days 90)
    aws s3api put-bucket-lifecycle-configuration --bucket "$STATE_BUCKET" \
        --lifecycle-configuration "{
            \"Rules\": [
                {
                    \"ID\": \"expire-noncurrent-versions\",
                    \"Status\": \"Enabled\",
                    \"Filter\": {},
                    \"NoncurrentVersionExpiration\": {\"NoncurrentDays\": ${retention}},
                    \"AbortIncompleteMultipartUpload\": {\"DaysAfterInitiation\": 7}
                }
            ]
        }" >/dev/null \
        || warn "could not set a lifecycle policy on s3://${STATE_BUCKET}"

    ok "state bucket s3://${STATE_BUCKET} ready (versioned, encrypted, private)"
}

# aws_state_key <component> - where this component's state object lives.
aws_state_key() {
    tfvars_load_identity
    printf '%s/%s/terraform.tfstate' "$STATE_PREFIX" "$1"
}

# aws_state_exists <component> - has this component ever been applied?
aws_state_exists() {
    tfvars_load_identity
    aws s3api head-object --bucket "$STATE_BUCKET" --key "$(aws_state_key "$1")" \
        >/dev/null 2>&1
}
