# Preflight assertions for the lifecycle scripts (#43). Source AFTER .env is loaded and $ROOT is set
# (i.e. after lib/xacct.sh / the .env load). Fail-fast BEFORE any mutation so a misconfigured shell
# aborts cleanly instead of half-destroying an estate (e.g. the 2026-07-07 teardown that ran as the
# management user against member accounts because WATCH_*_ACCOUNT_ID weren't loaded).
#
# The pinned-tofu assertion lives in lib/tofu.sh (sourced separately); this covers identity + env.

preflight() { # $1 = mode label (create|teardown|deploy|...); $2 = "dns" if the op touches Cloudflare
  local mode="${1:-op}" needs="${2:-}" errs=0 who=""

  who="$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)" || {
    echo "FATAL   : no valid AWS credentials (sts get-caller-identity failed). AWS_PROFILE=${AWS_PROFILE:-unset}" >&2
    errs=1; }

  # Cross-account: if either member id is set we're multi-account, so BOTH must be present + look like
  # 12-digit account ids. Blank-both = deliberate single-account mode (allowed). This is the exact gap
  # that let teardown run in the management account. (No ${!indirect} — keep it portable.)
  local d12='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
  if [ -n "${WATCH_NONPROD_ACCOUNT_ID:-}${WATCH_PROD_ACCOUNT_ID:-}" ]; then
    case "${WATCH_NONPROD_ACCOUNT_ID:-}" in $d12) : ;; *)
      echo "FATAL   : WATCH_NONPROD_ACCOUNT_ID unset/malformed ('${WATCH_NONPROD_ACCOUNT_ID:-}') — cross-account assume-role won't work. Source .env." >&2; errs=1 ;; esac
    case "${WATCH_PROD_ACCOUNT_ID:-}" in $d12) : ;; *)
      echo "FATAL   : WATCH_PROD_ACCOUNT_ID unset/malformed ('${WATCH_PROD_ACCOUNT_ID:-}') — cross-account assume-role won't work. Source .env." >&2; errs=1 ;; esac
  fi

  if [ "$needs" = dns ] && [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
    echo "FATAL   : CLOUDFLARE_API_TOKEN unset — DNS ($mode) will fail. Source .env." >&2; errs=1; fi

  [ "$errs" = 0 ] || { echo "preflight ($mode): FAILED — aborting before any mutation." >&2; exit 1; }
  # Name the detected topology (platform#50): blank-both member ids = single-account; both set =
  # two-member (org-created or existing-org — same mechanics, only the role name differs).
  local topo="single-account"
  [ -n "${WATCH_NONPROD_ACCOUNT_ID:-}" ] && topo="two-member (role=${WATCH_MEMBER_ROLE_NAME:-OrganizationAccountAccessRole})"
  echo "preflight ($mode): ok — caller=$who topology=$topo cross-account=$([ -n "${WATCH_NONPROD_ACCOUNT_ID:-}" ] && echo yes || echo no)"
}
