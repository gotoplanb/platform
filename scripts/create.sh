#!/usr/bin/env bash
# Deterministic (re)create of Watch's AWS stacks. Terragrunt's DAG orders + parallelizes
# automatically: ecr -> per-env network -> data/config -> app -> escalation/intake/frontend/
# observability -> prod/dns -> pipeline. Idempotent — re-run converges (no-op if current).
#
# Foundation kept across teardowns (see teardown.sh): the ECR repo + a :bootstrap image, the
# ACM cert, tf-state, account/*, github/*. This script self-heals a MISSING :bootstrap tag by
# seeding it from the newest image, so the app has something to pull on the first apply
# (CodeDeploy later promotes the real build by digest, ADR-017).
#
# Usage:
#   scripts/create.sh                 # both envs + pipeline (default), DAG-parallel
#   scripts/create.sh staging         # staging only
#   scripts/create.sh prod            # prod only
#   scripts/create.sh both -y         # skip the confirm prompt (automation)
#
# Env: AWS_PROFILE (default watch-bootstrap — needs write), AWS_REGION (default us-east-1),
#      TG_TF_PATH (default tofu). CLOUDFLARE_API_TOKEN is sourced from ./.env if present
#      (prod/dns needs it). Re-run is safe.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/lib/tofu.sh"  # pinned OpenTofu (.bin/tofu, .opentofu-version)
export AWS_PROFILE="${AWS_PROFILE:-watch-bootstrap}"
REGION="${AWS_REGION:-us-east-1}"
BASE="watch/$REGION"
REPO=watch

# Cross-account (ADR-020): the estate applies cross-account via terragrunt's provider assume_role,
# but the raw ECR :bootstrap self-heal below must target the foundation (nonprod) account that owns
# the repo. Load the member ids (for xacct) + the helper. Blank ids => single-account => no-op.
# shellcheck source=lib/xacct.sh
. "$ROOT/scripts/lib/xacct.sh"
[ -n "${WATCH_NONPROD_ACCOUNT_ID:-}${WATCH_PROD_ACCOUNT_ID:-}" ] || { [ -f .env ] && { set -a; . ./.env; set +a; }; }

# prod/dns reads CLOUDFLARE_API_TOKEN; load it from .env (never committed) if not already set.
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] && [ -f .env ]; then set -a; . ./.env; set +a; fi

# Fail-fast on missing account IDs / bad AWS identity before any apply (#43). CLOUDFLARE_API_TOKEN
# stays a soft warning for create (prod/dns tolerates it; see below), so no "dns" arg here.
. "$ROOT/scripts/lib/preflight.sh"
preflight create

# Order-tolerant args (#53): scope word and flags in any order; bad input is a LOUD fatal.
WHICH=""; ASSUME_YES=0
usage_fatal() {
  echo "==================================================================" >&2
  echo "FATAL   : bad argument '$1'" >&2
  echo "usage   : create.sh [staging|prod|both|pipeline] [-y]  (prefer: make create*)" >&2
  echo "==================================================================" >&2
  exit 2
}
for a in "$@"; do
  case "$a" in
    staging|prod|both|pipeline) [ -z "$WHICH" ] || usage_fatal "$a (scope already set to $WHICH)"; WHICH="$a" ;;
    -y|--yes) ASSUME_YES=1 ;;
    *) usage_fatal "$a" ;;
  esac
done
WHICH="${WHICH:-both}"

case "$WHICH" in
  staging)  DIR="$BASE/staging" ;;
  prod)     DIR="$BASE/prod" ;;
  both)     DIR="$BASE" ;;               # ecr + staging + prod + prod/dns + pipeline
  pipeline) DIR="$BASE/pipeline" ;;      # re-apply just the pipeline (repoint at current envs, #28)
esac

echo "Profile : $AWS_PROFILE"
aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || { echo "no AWS creds for $AWS_PROFILE" >&2; exit 1; }
echo "Region  : $REGION"
echo "Scope   : $WHICH  ($DIR)"
[ -z "${CLOUDFLARE_API_TOKEN:-}" ] && echo "WARN    : CLOUDFLARE_API_TOKEN unset — prod/dns will fail (set it or source .env)"

# --- ensure a :bootstrap image exists (the app task-def pulls <repo>:bootstrap) ---
# The ECR repo lives in the foundation (nonprod) account (ADR-020); assume in for these raw ECR
# calls, in a subshell so the estate apply below keeps the base (management) creds. No-op single-acct.
if ! (
  xacct_assume "$(xacct_account_for foundation)" >/dev/null
  if aws ecr describe-images --region "$REGION" --repository-name "$REPO" \
       --query 'imageDetails[?contains(imageTags,`bootstrap`)]' --output text 2>/dev/null | grep -q .; then
    echo "Bootstrap: :bootstrap image present."
  else
    NEWEST=$(aws ecr describe-images --region "$REGION" --repository-name "$REPO" \
       --query 'reverse(sort_by(imageDetails,&imagePushedAt))[0].imageTags[0]' --output text 2>/dev/null)
    if [ -z "$NEWEST" ] || [ "$NEWEST" = "None" ]; then
      echo "ERROR: ECR repo '$REPO' has no image to boot from." >&2
      echo "  The task definitions pull <repo>:bootstrap, which must exist before the services can" >&2
      echo "  start — and the pipeline can only build it AFTER the estate exists. So build it once," >&2
      echo "  from source, as a documented first-run step (ADR-047):" >&2
      echo "" >&2
      echo "      make bootstrap-image        # builds from ../watch, pushes <repo>:bootstrap" >&2
      echo "" >&2
      exit 1
    fi
    # Re-tagging the NEWEST image is a convenience for an estate that has been torn down and is
    # coming back — not a substitute for the first-run build. It resurrects whatever happens to be
    # newest, which in a long-lived repo is a build from days ago; a fresh estate then comes up on
    # STALE CODE, and every ordering bug we chased followed from that (platform#60/#61/#62). Say so
    # loudly rather than pretending this is the same thing as deploying the current code.
    echo "  NOTE: seeding :bootstrap from an EXISTING image, not from source. If you want the estate" >&2
    echo "        to boot on current code, run 'make bootstrap-image' first (ADR-047)." >&2
    echo "Bootstrap: seeding :bootstrap from newest image ($NEWEST)..."
    MANIFEST=$(aws ecr batch-get-image --region "$REGION" --repository-name "$REPO" \
       --image-ids imageTag="$NEWEST" --query 'images[0].imageManifest' --output text)
    aws ecr put-image --region "$REGION" --repository-name "$REPO" \
       --image-tag bootstrap --image-manifest "$MANIFEST" >/dev/null
    echo "  :bootstrap -> $NEWEST"
  fi
); then
  echo "ERROR: :bootstrap image check/seed failed (foundation account)" >&2; exit 1
fi

if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Apply $WHICH now? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
fi

apply_dir() { echo "==================== APPLY $1 ===================="; ( cd "$1" && terragrunt run --all apply --non-interactive ); }

apply_dir "$DIR"; rc=$?

# Recreating staging alone gives it new listener/target-group ARNs; the region pipeline bakes
# those into its staging CodeDeploy group, so re-apply the pipeline to repoint at the fresh
# staging (#28). `both` already includes the pipeline; `prod`/`pipeline` scopes don't need it.
if [ "$rc" -eq 0 ] && [ "$WHICH" = staging ]; then
  apply_dir "$BASE/pipeline"; rc=$?
fi

echo "==================== SUMMARY ===================="
if [ "$rc" -ne 0 ]; then echo "apply failed (rc=$rc) — inspect above; re-run is idempotent"; exit "$rc"; fi
echo "create complete ($WHICH)."

# First-ever create leaves the persistent GitHub connection PENDING (#33) — it needs the
# one-time browser authorization before the pipeline can pull the repo. It's KEPT across future
# recreates, so this only fires once.
if [ "$WHICH" = both ]; then
  cstat=$(aws codestar-connections list-connections --region "$REGION" \
    --query "Connections[?ConnectionName=='watch-github'].ConnectionStatus | [0]" --output text 2>/dev/null || true)
  if [ "$cstat" = "PENDING" ]; then
    echo "ACTION: connection 'watch-github' is PENDING — authorize it once (survives future recreates):"
    echo "        https://$REGION.console.aws.amazon.com/codesuite/settings/connections?region=$REGION"
  fi
fi

# A freshly-created V2 pipeline auto-starts one run (trigger=CreatePipeline). On a recreate we
# want the estate up on the :bootstrap image, with deploys coming from an explicit push (#24) —
# so abandon that redundant auto-run if it appeared.
case "$WHICH" in
  both|pipeline)
    for _ in 1 2 3; do
      read -r pst ptr < <(aws codepipeline list-pipeline-executions --region "$REGION" --pipeline-name watch \
        --query 'pipelineExecutionSummaries[0].[status,trigger.triggerType]' --output text 2>/dev/null || true)
      if [ "${ptr:-}" = "CreatePipeline" ] && [ "${pst:-}" = "InProgress" ]; then
        peid=$(aws codepipeline list-pipeline-executions --region "$REGION" --pipeline-name watch \
          --query 'pipelineExecutionSummaries[0].pipelineExecutionId' --output text 2>/dev/null)
        aws codepipeline stop-pipeline-execution --region "$REGION" --pipeline-name watch \
          --pipeline-execution-id "$peid" --abandon --reason "recreate: keep bootstrap; deploy via push" >/dev/null 2>&1 \
          && echo "Stopped the pipeline's auto-start run — deploy via a push (#24)."
        break
      fi
      sleep 5
    done ;;
esac

echo "Next: push to the tracked branch to run the pipeline (GitHub Actions → CodePipeline, #24)."
