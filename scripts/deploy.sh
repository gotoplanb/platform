#!/usr/bin/env bash
# Trigger a pipeline run to deploy the latest main — create.sh brings the app up on the
# :bootstrap seed image, this promotes real code through it. Same path as a push (#24), just
# started deterministically. Waits through Build -> DeployStaging -> DAST and stops at the
# prod approval gate (the human checkpoint — can't be automated). Runs standalone (`make
# deploy`) or as the last step of `make live`.
#
# Usage: scripts/deploy.sh [--no-wait]
# Env: AWS_PROFILE (default watch-bootstrap), AWS_REGION (us-east-1).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/xacct.sh
. "$ROOT/scripts/lib/xacct.sh"
[ -n "${WATCH_NONPROD_ACCOUNT_ID:-}${WATCH_PROD_ACCOUNT_ID:-}" ] || { [ -f .env ] && { set -a; . ./.env; set +a; }; }
export AWS_PROFILE="${AWS_PROFILE:-watch-bootstrap}"
REGION="${AWS_REGION:-us-east-1}"

# The pipeline + staging CodeDeploy live in the nonprod (platform/build) account (ADR-020); assume
# into it for StartPipelineExecution + the pre-flight. (watch-prod's CodeDeploy is in watch-prod —
# the list-deployment-groups call below just returns nothing for it here and skips, which is fine:
# prod deploys via the gated cross-account promote, not create's initial placement.)
xacct_assume "$(xacct_account_for foundation)"

NOWAIT=0
for a in "$@"; do case "$a" in --no-wait) NOWAIT=1 ;; *) echo "unknown flag: $a" >&2; exit 2 ;; esac; done

# Pre-flight: as the last step of `make live`, create.sh has just triggered CodeDeploy to place
# the initial (bootstrap) tasks. If we StartPipelineExecution while that deployment is still in
# flight, DeployStaging fails "Another deployment ... already in progress." Wait for both DGs to
# go idle first (bounded ~5 min; then proceed and let the pipeline surface any real problem).
for app in watch-staging watch-prod; do
  dg=$(aws deploy list-deployment-groups --region "$REGION" --application-name "$app" --query 'deploymentGroups[0]' --output text 2>/dev/null)
  [ -n "$dg" ] && [ "$dg" != "None" ] || continue
  for _ in $(seq 1 30); do
    busy=$(aws deploy list-deployments --region "$REGION" --application-name "$app" --deployment-group-name "$dg" \
      --include-only-statuses Created Queued InProgress Ready --query 'length(deployments)' --output text 2>/dev/null)
    [ "${busy:-0}" = 0 ] && break
    echo "  waiting for an in-flight CodeDeploy deployment on $app to finish..."; sleep 10
  done
done

EID=$(aws codepipeline start-pipeline-execution --region "$REGION" --name watch --query pipelineExecutionId --output text 2>&1)
[ -n "$EID" ] && [ "$EID" != "None" ] || { echo "failed to start pipeline: $EID" >&2; exit 1; }
echo "Started pipeline execution: $EID"
if [ "$NOWAIT" = 1 ]; then echo "(not waiting) — watch it in the CodePipeline console."; exit 0; fi

st() { # status of a stage's action in this execution
  aws codepipeline list-action-executions --region "$REGION" --pipeline-name watch \
    --filter pipelineExecutionId="$EID" \
    --query "actionExecutionDetails[?stageName=='$1'].status | [0]" --output text 2>/dev/null
}

echo "Waiting through Build -> DeployStaging -> DAST -> prod approval gate..."
for _ in $(seq 1 100); do
  B=$(st Build); D=$(st DeployStaging); Z=$(st DAST); A=$(st ApproveProd)
  echo "  Build=$B Deploy=$D DAST=$Z Approve=$A"
  for s in "$B" "$D" "$Z"; do
    [ "$s" = "Failed" ] && { echo "FAILED before the gate — inspect the pipeline."; exit 1; }
  done
  [ "$A" = "InProgress" ] && { echo "Reached the prod approval gate — approve to promote to prod (staging is live on latest + DAST passed)."; exit 0; }
  [ "$A" = "Succeeded" ] && { echo "Prod already promoted."; exit 0; }
  sleep 20
done
echo "Still running after the wait window — check the console."; exit 0
