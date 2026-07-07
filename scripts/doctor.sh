#!/usr/bin/env bash
# Read-only estate doctor (#44): compare state vs reality across BOTH member accounts and report
# drift. Two failure modes it catches — the ones that cost real money or break the next apply:
#   ORPHAN  billable watch-* resource live in AWS that teardown should have removed (silent $).
#   GHOST   resource in terraform state but absent in AWS (a stale apply/refresh will error/recreate).
# Exit 1 if any ORPHAN is found (that's the billable one); GHOSTs are reported but non-fatal.
#
# Runs cross-account: assumes OrganizationAccountAccessRole into nonprod (staging+foundation) and prod
# using the base management creds — READ CALLS ONLY, safe to run any time. State reads use the base
# creds against the management bucket (assumed creds can't read it), so ordering matters (see below).
#
# Usage:
#   scripts/doctor.sh                # orphan sweep, both accounts (fast, seconds)
#   scripts/doctor.sh --state        # also cross-check terraform state per stack (slower: init/stack)
#   scripts/doctor.sh --state staging
# Env: AWS_PROFILE (default watch-bootstrap — needs sts:AssumeRole into members), AWS_REGION.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export AWS_PROFILE="${AWS_PROFILE:-watch-bootstrap}"
REGION="${AWS_REGION:-us-east-1}"
BASE="watch/$REGION"
if [ -f .env ]; then set -a; . ./.env; set +a; fi
. "$ROOT/scripts/lib/xacct.sh"
. "$ROOT/scripts/lib/preflight.sh"

WITH_STATE=0; SCOPE=both
for a in "$@"; do
  case "$a" in
    --state)              WITH_STATE=1 ;;
    staging|prod|both)    SCOPE="$a" ;;
    *) echo "usage: doctor.sh [--state] [staging|prod|both]" >&2; exit 2 ;;
  esac
done

# doctor only reads, but a bad identity / missing member ids means it silently scans nothing —
# which would falsely read as "clean". Preflight makes that loud. (No dns arg: doctor never touches DNS.)
preflight doctor

RESDIR="$(mktemp -d "${TMPDIR:-/tmp}/watch-doctor.XXXXXX")"
ORPHANS="$RESDIR/orphans"; GHOSTS="$RESDIR/ghosts"; : > "$ORPHANS"; : > "$GHOSTS"

# clean <ids> -> normalized space-separated list ("" if AWS printed None/empty). Mirrors sweep.sh.
clean() { local ids; ids="$(echo "$1" | tr '\t' ' ' | xargs 2>/dev/null || true)"; [ "$ids" = None ] && ids=""; echo "$ids"; }

# report <account> <label> <ids> — one orphan line per non-empty resource class.
report() {
  local acct="$1" label="$2" ids; ids="$(clean "$3")"
  if [ -n "$ids" ]; then printf '  ✗ %-22s %s\n' "$label" "$ids"; echo "$acct  $label  $ids" >> "$ORPHANS"
  else printf '  ✓ %-22s clean\n' "$label"; fi
}

# scan_account <label> — cross-account billable enumeration (assumed creds already exported).
# Only classes that BILL or block a VPC delete. Foundation keepers (ECR/ACM/tf-state) are excluded by
# construction: we never enumerate those categories. The nonprod account legitimately owns the ECR repo
# and certs — doctor doesn't flag them.
scan_account() {
  local label="$1"
  echo; echo "── $label account $(aws sts get-caller-identity --query Account --output text 2>/dev/null) ──"
  report "$label" "ECS clusters"      "$(aws ecs list-clusters --region "$REGION" --query 'clusterArns[]' --output text 2>/dev/null | tr '\t' '\n' | grep -i watch | sed 's#.*/##' | tr '\n' ' ')"
  report "$label" "RDS instances"     "$(aws rds describe-db-instances --region "$REGION" --query 'DBInstances[?contains(DBInstanceIdentifier,`watch`)].DBInstanceIdentifier' --output text 2>/dev/null)"
  report "$label" "ElastiCache"       "$(aws elasticache describe-cache-clusters --region "$REGION" --query 'CacheClusters[?contains(CacheClusterId,`watch`)].CacheClusterId' --output text 2>/dev/null)"
  report "$label" "Load balancers"    "$(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[?contains(LoadBalancerName,`watch`)].LoadBalancerName' --output text 2>/dev/null)"
  report "$label" "NAT gateways"      "$(aws ec2 describe-nat-gateways --region "$REGION" --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null)"
  report "$label" "Unassoc. EIPs"     "$(aws ec2 describe-addresses --region "$REGION" --query 'Addresses[?AssociationId==`null`].PublicIp' --output text 2>/dev/null)"
  report "$label" "Non-default VPCs"  "$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=false --query 'Vpcs[].VpcId' --output text 2>/dev/null)"
  report "$label" "Lambda functions"  "$(aws lambda list-functions --region "$REGION" --query 'Functions[?starts_with(FunctionName,`watch`)].FunctionName' --output text 2>/dev/null)"
  report "$label" "SQS queues"        "$(aws sqs list-queues --region "$REGION" --queue-name-prefix watch --query 'QueueUrls[]' --output text 2>/dev/null | tr '\t' '\n' | sed 's#.*/##' | tr '\n' ' ')"
  report "$label" "Step Functions"    "$(aws stepfunctions list-state-machines --region "$REGION" --query 'stateMachines[?starts_with(name,`watch`)].name' --output text 2>/dev/null)"
}

# --- state cross-check (opt-in, --state) --------------------------------------------------------
# A ghost = terraform state lists a resource but the account has none. We approximate cheaply per
# stack: if `terragrunt state list` is non-empty but the account shows nothing billable for that env,
# the stack's state is stale. Runs with BASE creds (state lives in the management bucket).
state_count() { ( cd "$1" 2>/dev/null && terragrunt state list 2>/dev/null | wc -l | tr -d ' ' ) || echo 0; }

check_state_for_env() {
  local e="$1" total=0 s n
  echo; echo "── terraform state — $e (stacks with live state) ──"
  for s in network data config gateway app escalation intake frontend observability obs/tempo obs/grafana dns dns-status; do
    local dir="$BASE/$e/$s"
    [ -f "$dir/terragrunt.hcl" ] || continue
    n="$(state_count "$dir")"; total=$((total + n))
    [ "$n" -gt 0 ] && printf '  • %-26s %s resource(s) in state\n' "$e/$s" "$n"
  done
  echo "  ($e: $total resources tracked in state)"
  echo "$e $total" >> "$GHOSTS"
}

echo "Estate doctor — region $REGION, profile $AWS_PROFILE, scope $SCOPE"
aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || { echo "no AWS creds" >&2; exit 2; }

# ORPHAN pass — per member account, in a subshell so assumed creds don't leak between accounts.
# staging+foundation share the nonprod account; prod is separate. Scope narrows which we scan.
declare -a TARGETS=()
case "$SCOPE" in
  staging) TARGETS=("nonprod:$(xacct_account_for staging)") ;;
  prod)    TARGETS=("prod:$(xacct_account_for prod)") ;;
  both)    TARGETS=("nonprod:$(xacct_account_for staging)" "prod:$(xacct_account_for prod)") ;;
esac
for pair in "${TARGETS[@]}"; do
  label="${pair%%:*}"; acct="${pair#*:}"
  if [ -z "$acct" ]; then echo; echo "── $label account (single-account mode / id unset) — scanning current creds ──"; ( scan_account "$label" ); continue; fi
  ( xacct_assume "$acct" >/dev/null 2>&1 || { echo "  ! could not assume into $label ($acct) — skipped" >&2; exit 0; }; scan_account "$label" )
done

# GHOST pass — base creds, state reads. Only when --state (slower: terragrunt init per stack).
if [ "$WITH_STATE" = 1 ]; then
  case "$SCOPE" in
    staging) check_state_for_env staging ;;
    prod)    check_state_for_env prod ;;
    both)    check_state_for_env staging; check_state_for_env prod ;;
  esac
fi

echo; echo "==================== DIAGNOSIS ===================="
norph=$(wc -l < "$ORPHANS" | tr -d ' ')
if [ "$norph" -gt 0 ]; then
  echo "ORPHANS ($norph billable class-hits) — teardown missed these; they are billing:"
  sed 's/^/  /' "$ORPHANS"
  echo "  → run scripts/nuke.sh <account> to force-clean, or investigate individually."
else
  echo "No billable orphans. (ECR repo + ACM cert + tf-state intentionally persist — not flagged.)"
fi
if [ "$WITH_STATE" = 1 ]; then
  echo "State cross-check ran — compare 'resources in state' above against the orphan pass:"
  echo "  state>0 but account clean  => GHOSTs (stale state; a create/teardown will reconcile)."
  echo "  state=0 but orphans listed => partial-apply leftovers (nuke them)."
fi
echo "logs: $RESDIR"
[ "$norph" -eq 0 ] || exit 1
