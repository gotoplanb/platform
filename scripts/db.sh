#!/usr/bin/env bash
# One-off DB tasks as a Fargate run-task on the app service's task definition. Mirrors the
# CodeDeploy migrate hook (modules/pipeline/hook) but standalone — needed after create.sh,
# where the bootstrap image runs against an EMPTY database until migrated. Both envs are ha
# (private subnets + NAT), so the task runs in the private subnets with the app SG.
#
# Usage:
#   scripts/db.sh migrate [staging|prod]     # python manage.py migrate --noinput
#   scripts/db.sh seed    [staging|prod]     # python manage.py seed_demo  (t1a..t3b + demo data)
#   scripts/db.sh run "manage.py check" [env] # arbitrary one-off command on the app container
#
# Env: AWS_PROFILE (default watch-bootstrap), AWS_REGION (us-east-1), TG_TF_PATH (tofu).
# Waits for the task to stop, prints the app container's exit code + tail of its logs, and
# exits nonzero if the command failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/xacct.sh
. "$ROOT/scripts/lib/xacct.sh"
[ -n "${WATCH_NONPROD_ACCOUNT_ID:-}${WATCH_PROD_ACCOUNT_ID:-}" ] || { [ -f .env ] && { set -a; . ./.env; set +a; }; }
export TG_TF_PATH="${TG_TF_PATH:-tofu}"
export AWS_PROFILE="${AWS_PROFILE:-watch-bootstrap}"
REGION="${AWS_REGION:-us-east-1}"
BASE="watch/$REGION"
CONTAINER=app

ACTION="${1:?usage: db.sh <migrate|seed|run> [env] ; run takes a quoted command}"
case "$ACTION" in
  migrate) ENV="${2:-prod}"; CMD=(python manage.py migrate --noinput) ;;
  seed)    ENV="${2:-prod}"; CMD=(python manage.py seed_demo) ;;
  run)     CMD_STR="${2:?run needs a quoted command}"; ENV="${3:-prod}"; read -r -a CMD <<< "python $CMD_STR" ;;
  *) echo "usage: db.sh <migrate|seed|run> [staging|prod]" >&2; exit 2 ;;
esac
case "$ENV" in staging|prod) ;; *) echo "env must be staging|prod" >&2; exit 2 ;; esac

CMD_JSON=$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1:]))' "${CMD[@]}")
FAMILY="watch-$ENV"
LOG_GROUP="/ecs/watch-$ENV"

echo "Resolving $ENV stack outputs..."
CLUSTER=$(cd "$BASE/$ENV/app"     && terragrunt output -raw cluster_name)
SG=$(cd "$BASE/$ENV/network"      && terragrunt output -raw app_sg_id)
SUBNETS_JSON=$(cd "$BASE/$ENV/network" && terragrunt output -json private_subnet_ids)
NETCFG=$(printf '{"awsvpcConfiguration":{"subnets":%s,"securityGroups":["%s"],"assignPublicIp":"DISABLED"}}' "$SUBNETS_JSON" "$SG")
OVERRIDES=$(printf '{"containerOverrides":[{"name":"%s","command":%s}]}' "$CONTAINER" "$CMD_JSON")

# State was read with the base (management) creds above; the ECS cluster lives in the env's member
# account (ADR-020), so assume into it for the run-task + waits + logs. No-op in single-account mode.
xacct_assume "$(xacct_account_for "$ENV")"

echo "Running on $ENV: ${CMD[*]}"
ARN=$(aws ecs run-task --region "$REGION" --cluster "$CLUSTER" --task-definition "$FAMILY" \
        --launch-type FARGATE --network-configuration "$NETCFG" --overrides "$OVERRIDES" \
        --query 'tasks[0].taskArn' --output text)
[ -z "$ARN" ] || [ "$ARN" = "None" ] && { echo "run-task did not start a task" >&2; exit 1; }
TASK_ID="${ARN##*/}"
echo "  task $TASK_ID — waiting for it to stop (up to ~8 min)..."
aws ecs wait tasks-stopped --region "$REGION" --cluster "$CLUSTER" --tasks "$ARN"

CODE=$(aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "$ARN" \
        --query "tasks[0].containers[?name=='$CONTAINER'].exitCode | [0]" --output text)
echo "--- logs ($LOG_GROUP : $CONTAINER/$CONTAINER/$TASK_ID) ---"
aws logs get-log-events --region "$REGION" --log-group-name "$LOG_GROUP" \
  --log-stream-name "$CONTAINER/$CONTAINER/$TASK_ID" --limit 60 \
  --query 'events[].message' --output text 2>/dev/null | sed 's/^/  /' || echo "  (no logs yet)"

echo "exit code: $CODE"
[ "$CODE" = "0" ] || { echo "FAILED ($ACTION on $ENV)"; exit 1; }
echo "OK ($ACTION on $ENV)"
