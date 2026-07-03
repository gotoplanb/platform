# Cross-account helper (ADR-020). Assume OrganizationAccountAccessRole into the member account for
# a given env, so the raw-AWS-CLI lifecycle steps (ecs run-task, s3 sync, StartPipeline) hit the
# right account. The base creds (AWS_PROFILE) must be in the MANAGEMENT account. Read the member
# ids from the environment (source .env first). Blank ids => single-account mode => no-op.
#
# IMPORTANT: run `terragrunt output` (state reads, in the management bucket) with the BASE creds
# FIRST, then xacct_assume before the member-account resource calls — assumed creds can't read the
# management state bucket.

xacct_account_for() { # $1 = staging|prod|foundation -> the member account id (or "")
  case "$1" in
    prod)                 printf '%s' "${WATCH_PROD_ACCOUNT_ID:-}" ;;
    staging | foundation) printf '%s' "${WATCH_NONPROD_ACCOUNT_ID:-}" ;;
    *)                    printf '%s' "" ;;
  esac
}

xacct_assume() { # $1 = account id; exports temp creds for it. Blank => no-op (single-account).
  local acct="$1" creds
  [ -n "$acct" ] || return 0
  creds=$(aws sts assume-role \
    --role-arn "arn:aws:iam::${acct}:role/OrganizationAccountAccessRole" \
    --role-session-name "watch-lifecycle-$$" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text) || {
    echo "xacct: failed to assume into ${acct}" >&2
    return 1
  }
  export AWS_ACCESS_KEY_ID="$(printf '%s' "$creds" | awk '{print $1}')"
  export AWS_SECRET_ACCESS_KEY="$(printf '%s' "$creds" | awk '{print $2}')"
  export AWS_SESSION_TOKEN="$(printf '%s' "$creds" | awk '{print $3}')"
  unset AWS_PROFILE # temp creds win; avoid a profile/creds conflict
  echo "xacct: assumed into ${acct}"
}
