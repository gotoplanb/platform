#!/usr/bin/env bash
# Topology smoke (platform#50) — READ-ONLY. Verifies the configured deployment topology
# actually works before any create/apply:
#   single-account : both WATCH_*_ACCOUNT_ID blank -> everything targets the current account
#   two-member     : both set -> assume-role into each member must succeed (org-created OR
#                    existing-org; only WATCH_MEMBER_ROLE_NAME differs)
# Checks: preflight (identity + 0-or-2 id rule), STS assume into each member, state-backend
# reachability. PLAN=1 additionally runs a representative `terragrunt plan` (slower; still
# read-only). Exits nonzero on any failure.
#
#   scripts/topology-check.sh            # fast: identity + assume + state backend
#   PLAN=1 scripts/topology-check.sh     # + a representative terragrunt plan per routing class
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ -n "${WATCH_NONPROD_ACCOUNT_ID:-}${WATCH_PROD_ACCOUNT_ID:-}" ] || { [ -f .env ] && { set -a; . ./.env; set +a; }; }
. "$ROOT/scripts/lib/preflight.sh"
preflight "topology-check"

fails=0
role="${WATCH_MEMBER_ROLE_NAME:-OrganizationAccountAccessRole}"
project="${WATCH_PROJECT:-watch}"
hub="$(aws sts get-caller-identity --query 'Account' --output text)"

check_assume() { # $1 = label, $2 = account id
  local arn
  arn=$(aws sts assume-role \
    --role-arn "arn:aws:iam::${2}:role/${role}" \
    --role-session-name "topology-check-$$" \
    --query 'AssumedRoleUser.Arn' --output text 2>/dev/null) \
    && echo "assume  : $1 (${2}) via ${role} -> OK ($arn)" \
    || { echo "assume  : $1 (${2}) via ${role} -> FAILED (role missing or untrusted; see member-access/README.md)" >&2; fails=1; }
}

if [ -n "${WATCH_NONPROD_ACCOUNT_ID:-}" ]; then
  check_assume nonprod "$WATCH_NONPROD_ACCOUNT_ID"
  check_assume prod    "$WATCH_PROD_ACCOUNT_ID"
else
  echo "assume  : single-account — no member roles to test (all stacks target ${hub})"
fi

bucket="${project}-tfstate-${hub}"
if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
  echo "state   : s3://${bucket} reachable"
else
  echo "state   : s3://${bucket} MISSING — run ./bootstrap once (see bootstrap/README.md)" >&2
  fails=1
fi

# Foundation pinning (#52): the KEPT stacks (connection, ci-trigger) survive teardown, and
# their state binds them to the account they were created in. If current routing targets a
# different account, their next refresh fails AccessDenied (the cycle-C failure mode of the
# 2026-07-12 rehearsal). Compare each kept stack's state-recorded account to the routing target.
foundation_target="${WATCH_NONPROD_ACCOUNT_ID:-$hub}"   # foundation class routes to nonprod, else hub
for stack in connection ci-trigger; do
  key="watch/us-east-1/${stack}/terraform.tfstate"
  state_acct=$(aws s3 cp "s3://${bucket}/${key}" - 2>/dev/null \
    | grep -oE 'arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:' | head -1 | grep -oE '[0-9]{12}' || true)
  [ -n "$state_acct" ] || { echo "pinning : $stack — no state (never created here); skipping"; continue; }
  if [ "$state_acct" = "$foundation_target" ]; then
    echo "pinning : $stack state is in ${state_acct} — matches current routing"
  else
    echo "pinning : $stack state is PINNED to ${state_acct}, but current routing targets ${foundation_target}." >&2
    echo "          Applying it in this topology will fail (AccessDenied on refresh). Destroy it under" >&2
    echo "          the OLD .env before switching, or accept CI/CD plumbing stays in ${state_acct}" >&2
    echo "          (docs/TOPOLOGIES.md → 'Switching topologies')." >&2
    fails=1
  fi
done

if [ "${PLAN:-0}" = 1 ] && [ "$fails" = 0 ]; then
  . "$ROOT/scripts/lib/tofu.sh"
  # One cheap stack per routing class: management-routed, member-routed (skipped when
  # single-account collapses them to the same thing).
  plan_stack() { # $1 = path
    echo "plan    : $1 …"
    (cd "$1" && terragrunt plan -input=false -lock=false >/dev/null 2>&1) \
      && echo "plan    : $1 -> OK" \
      || { echo "plan    : $1 -> FAILED (run terragrunt plan there for detail)" >&2; fails=1; }
  }
  plan_stack account/github-oidc
  [ -n "${WATCH_NONPROD_ACCOUNT_ID:-}" ] && plan_stack member-ci/nonprod
fi

[ "$fails" = 0 ] && echo "topology: PASS" || { echo "topology: FAIL" >&2; exit 1; }
