# Cross-account helper (ADR-020, ADR-044, ADR-046). Assume the role that the raw-AWS-CLI lifecycle
# steps (ecs run-task, s3 sync, CreateInvalidation, StartPipelineExecution) run as, so they hit the
# right account AS THE RIGHT IDENTITY. The base creds (AWS_PROFILE) must be in the MANAGEMENT
# account. Read the member ids from the environment (source .env first).
#
# It now defaults to the FENCED PROVISIONER, and assumes it even when the target is the current
# account. Both of those were holes, and the ADR-046 drift report found them on its first run: it
# reported OUR OWN `watch-bootstrap` admin key doing RunTask / CreateInvalidation /
# StartPipelineExecution. `make live` was applying through the provisioner and then doing its
# finishing moves as admin — which is precisely the credential ADR-044 exists to stop needing.
#
# Two knobs, the same ones the terragrunt root reads, so the two can never disagree about who they
# are (test/topology_test.go asserts that for terragrunt; the default here mirrors it):
#   WATCH_MEMBER_ROLE_NAME  the role to assume (default: <project>-provisioner)
#   WATCH_ASSUME_IN_ACCOUNT 0 disables the in-account assume (the bootstrap apply that MINTS the
#                           provisioner has to run as admin — it is the one step that cannot use it)
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

xacct_assume() { # $1 = account id; exports temp creds for it. Blank => the CURRENT account.
  local acct="$1" creds role
  role="${WATCH_MEMBER_ROLE_NAME:-${WATCH_PROJECT:-watch}-provisioner}"

  # A blank id means "no separate member account" — NOT "no identity to assume". The lifecycle steps
  # still have to run as the provisioner, in whatever account they are already in. Skipping the
  # assume here is what left them on the bootstrap admin key in the single-account topology.
  [ -n "$acct" ] || acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || return 1

  # The one step that legitimately cannot be the provisioner is the admin apply that CREATES it.
  if [ "${WATCH_ASSUME_IN_ACCOUNT:-1}" = "0" ] &&
    [ "$acct" = "$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" ]; then
    echo "xacct: WATCH_ASSUME_IN_ACCOUNT=0 — staying on base creds in ${acct}"
    return 0
  fi

  creds=$(aws sts assume-role \
    --role-arn "arn:aws:iam::${acct}:role/${role}" \
    --role-session-name "watch-lifecycle-$$" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text) || {
    echo "xacct: failed to assume ${role} in ${acct}" >&2
    return 1
  }
  export AWS_ACCESS_KEY_ID="$(printf '%s' "$creds" | awk '{print $1}')"
  export AWS_SECRET_ACCESS_KEY="$(printf '%s' "$creds" | awk '{print $2}')"
  export AWS_SESSION_TOKEN="$(printf '%s' "$creds" | awk '{print $3}')"
  unset AWS_PROFILE # temp creds win; avoid a profile/creds conflict
  echo "xacct: assumed ${role} in ${acct}"
}
