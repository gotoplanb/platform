#!/usr/bin/env bash
# Finish a `make live` that stopped short because create.sh aborted on the new-account holds
# (CloudFront verification / CodeBuild concurrency, ADR-020): run the post-create steps the
# aborted make target + the blocked pipeline never reached. Idempotent — safe to re-run.
#
# Steps (order matters): migrate -> promote escalation Lambdas -> seed -> app DNS records.
# Lambdas are promoted BEFORE seeding so the demo incident's escalation Lambdas don't throw and trip
# the `watch-<env>-escalation-engine-error` deploy gate (ADR-048). Becomes a no-op / unnecessary once
# AWS clears the holds (the pipeline then does migrate-hook + Lambda promote + frontend itself).
#
# Usage: scripts/live-finish.sh [both|staging|prod]     (default: both)
# Env:   LAMBDA_ENVS (envs whose app runs newer-than-bootstrap code; default "staging"),
#        AWS_PROFILE (default watch-bootstrap), WATCH_REPO (default ../watch).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -n "${WATCH_NONPROD_ACCOUNT_ID:-}${WATCH_PROD_ACCOUNT_ID:-}" ] || { [ -f .env ] && { set -a; . ./.env; set +a; }; }
export AWS_PROFILE="${AWS_PROFILE:-watch-bootstrap}"
. "$ROOT/scripts/lib/tofu.sh"  # pinned OpenTofu (.bin/tofu, .opentofu-version)
REGION="${AWS_REGION:-us-east-1}"
LAMBDA_ENVS="${LAMBDA_ENVS:-staging}"

case "${1:-both}" in
  both) ENVS=(staging prod) ;;
  staging | prod) ENVS=("${1}") ;;
  *) echo "usage: live-finish.sh [both|staging|prod]" >&2; exit 2 ;;
esac

step() { echo; echo "==================== $* ===================="; }

# 1) migrate (tables must exist before the Lambdas run or the demo incident seeds)
for e in "${ENVS[@]}"; do step "migrate $e"; scripts/db.sh migrate "$e" || exit 1; done

# 2) promote the escalation Lambdas for the new-code env(s), before seeding
step "promote escalation Lambdas ($LAMBDA_ENVS)"
# only promote envs we were asked to finish
for e in $LAMBDA_ENVS; do case " ${ENVS[*]} " in *" $e "*) scripts/lambda-promote.sh "$e" || exit 1 ;; esac; done

# 3) seed demo data (the demo incident starts an escalation execution -> now succeeds)
for e in "${ENVS[@]}"; do step "seed $e"; scripts/db.sh seed "$e" || exit 1; done

# 4) app DNS records — create.sh skips staging/dns (dependent of the CloudFront-blocked frontend);
#    the app CNAME is gated independently, so applying the stack lands just the app record.
for e in "${ENVS[@]}"; do
  d="watch/$REGION/$e/dns"
  [ -d "$d" ] || continue
  step "app DNS $e"
  ( cd "$d" && terragrunt apply -auto-approve -no-color ) 2>&1 | grep -iE "Apply complete|cloudflare_record|Error" || true
done

step "verify"
scripts/live-verify.sh "${1:-both}" || { echo "live-finish: post-finish verify FAILED" >&2; exit 1; }

step "live-finish complete (${ENVS[*]})"
