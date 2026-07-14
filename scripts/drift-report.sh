#!/usr/bin/env bash
# Click-ops / drift report (ADR-046). Read-only. Answers two DIFFERENT questions, because
# either one alone lies to you:
#
#   1. WHAT actually drifted  — `terragrunt run --all plan -refresh-only` per account.
#      Refresh-only compares STATE against REALITY and reports nothing else. That is the whole
#      trick: a plain `plan` in this repo screams "500 to add" whenever the estate is torn down
#      (which is normal — we destroy it daily), and unapplied commits show up as config drift
#      that isn't drift at all. Refresh-only says only "objects have changed outside OpenTofu",
#      which is exactly the question. A deleted-by-hand resource shows up here too (state has it,
#      AWS doesn't).
#
#   2. WHO changed it — CloudTrail management events for the last N hours, minus the identities
#      that are ALLOWED to write. No trail is required: CloudTrail Event history retains 90 days
#      of management events for free and `lookup-events` reads it. So this whole report costs
#      $0 in AWS resources — no trail, no SNS, no EventBridge, no log ingestion.
#
# The allowlist is only trustworthy because of ADR-044: since the provisioner replaced
# bootstrap-admin, "changed outside terragrunt" has a crisp definition — any write NOT made by
# watch-provisioner, the pipeline's deploy roles, or an AWS service. Before the fence, every
# human and every robot looked the same (admin), and this report would have been meaningless.
#
# COMPLEMENTS `make doctor` (#44), which is about EXISTENCE drift and money: orphans (billable
# resources left live in AWS) and ghosts (in state, gone from AWS). This script is about ATTRIBUTE
# drift and ATTRIBUTION: someone edited a live resource, and who. Neither subsumes the other; run
# both. (doctor answers "is anything costing me money"; this answers "did someone click".)
#
# Usage: scripts/drift-report.sh [--hours 24] [--markdown]
# Env:   AWS_PROFILE (default watch-ro), AWS_REGION (us-east-1)
# Exit:  0 = clean, 1 = drift and/or click-ops found (so CI can gate on it).
set -uo pipefail
cd "$(dirname "$0")/.."

export AWS_PROFILE="${AWS_PROFILE:-watch-ro}"
REGION="${AWS_REGION:-us-east-1}"
HOURS=24
MARKDOWN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) HOURS="$2"; shift 2 ;;
    --markdown) MARKDOWN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=lib/xacct.sh
. scripts/lib/xacct.sh
[ -f .env ] && { set -a; . ./.env; set +a; }

HUB="$(aws sts get-caller-identity --query Account --output text)"
NONPROD="${WATCH_NONPROD_ACCOUNT_ID:-}"
PROD="${WATCH_PROD_ACCOUNT_ID:-}"
PROJECT="${WATCH_PROJECT:-watch}"

findings=0
CLICKOPS_MD=""
DRIFT_MD=""

say() { [ "$MARKDOWN" = 1 ] || echo "$@"; }

# ---------------------------------------------------------------------------
# 1. WHO — click-ops attribution, from CloudTrail Event history (no trail needed).
# ---------------------------------------------------------------------------
clickops_for() { # $1 = account id ("" = current), $2 = label
  local acct="$1" label="$2" events
  ( [ -n "$acct" ] && [ "$acct" != "$HUB" ] && xacct_assume "$acct" >/dev/null 2>&1
    events=$(aws --region "$REGION" cloudtrail lookup-events \
      --lookup-attributes AttributeKey=ReadOnly,AttributeValue=false \
      --start-time "$(date -u -v-"${HOURS}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ)" \
      --max-items 1000 --output json 2>/dev/null)
    [ -z "$events" ] && exit 0
    echo "$events" | PROJECT="$PROJECT" LABEL="$label" python3 scripts/lib/clickops_filter.py
  )
}

say "── click-ops (writes not made by terragrunt/AWS, last ${HOURS}h) ──"
for pair in "${HUB}:hub" "${NONPROD}:nonprod" "${PROD}:prod"; do
  acct="${pair%%:*}"; label="${pair##*:}"
  [ -z "$acct" ] && continue
  out=$(clickops_for "$acct" "$label")
  if [ -n "$out" ]; then
    findings=$((findings + 1))
    CLICKOPS_MD="${CLICKOPS_MD}${out}"$'\n'
    say "$out"
  else
    say "  ✓ ${label} (${acct}) — every write was terragrunt or an AWS service"
  fi
done

# ---------------------------------------------------------------------------
# 2. WHAT — real state-vs-reality drift. Refresh-only: nothing else counts.
# ---------------------------------------------------------------------------
say ""
say "── state drift (terragrunt plan -refresh-only) ──"
# Drive this off the STATE BUCKET, not `run --all`, for two reasons:
#
#   1. `run --all` aborts the whole run when a torn-down stack's dependency has no outputs — and
#      this estate is torn down most nights. The first version of this script did exactly that and
#      reported "clean" while a hand-edited role sat in front of it. A detector that fails silent
#      is worse than no detector, because you trust it.
#   2. "State vs reality" is only a question for stacks that HAVE state. A stack that was never
#      applied cannot have drifted; it is simply not deployed. Iterating the state objects gets
#      that distinction for free.
#
# Read the plan as JSON rather than grepping its prose. OpenTofu prints "# x has changed" whenever a
# refresh turns `tags = null` into `tags = {}` — the API answering with empty defaults, not a human
# editing anything. Every budget stack does it on every run. Grep cannot tell that from real drift;
# the JSON before/after can (scripts/lib/drift_filter.py). A report that is never clean gets muted.
state_keys=$(aws --region "$REGION" s3api list-objects-v2 \
  --bucket "${PROJECT}-tfstate-${HUB}" \
  --query 'Contents[?ends_with(Key, `terraform.tfstate`)].Key' --output text 2>/dev/null | tr '\t' '\n')

drift_out=""
for key in $state_keys; do
  stack="${key%/terraform.tfstate}"
  [ -d "$stack" ] || continue # state left behind by a stack that no longer exists in the repo
  out=$( cd "$stack" &&
    TG_TF_PATH=tofu terragrunt plan -refresh-only -out=drift.tfplan -no-color --non-interactive >/dev/null 2>&1 &&
    TG_TF_PATH=tofu terragrunt show -json drift.tfplan 2>/dev/null | python3 "$OLDPWD/scripts/lib/drift_filter.py"
    rm -f drift.tfplan )
  [ -n "$out" ] && drift_out="${drift_out}${stack}"$'\n'"${out}"$'\n'
done

if [ -n "$drift_out" ]; then
  findings=$((findings + 1))
  DRIFT_MD="$drift_out"
  say "$drift_out" | head -40
else
  say "  ✓ state matches reality — a terragrunt refresh would change nothing"
fi

# ---------------------------------------------------------------------------
if [ "$MARKDOWN" = 1 ]; then
  echo "## Drift report — last ${HOURS}h"
  echo
  if [ -z "$CLICKOPS_MD" ] && [ -z "$DRIFT_MD" ]; then
    echo "✓ **Clean.** Every write was made by terragrunt (\`${PROJECT}-provisioner\`), the pipeline, or an AWS service, and state matches reality."
  fi
  if [ -n "$CLICKOPS_MD" ]; then
    echo "### Click-ops: writes not made by terragrunt"
    echo
    echo "Someone changed AWS outside \`terragrunt apply\`. That is not automatically wrong — but it is invisible to the repo, and the next apply may revert it."
    echo
    echo '| when | account | who | action | resource |'
    echo '|---|---|---|---|---|'
    echo "$CLICKOPS_MD"
  fi
  if [ -n "$DRIFT_MD" ]; then
    echo "### State drift: reality no longer matches state"
    echo
    echo '```'
    echo "$DRIFT_MD" | head -60
    echo '```'
  fi
fi

[ "$findings" -eq 0 ] || exit 1
