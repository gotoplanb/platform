#!/usr/bin/env bash
# Read-only smoke check that a finished estate is actually serving: per env, the app (and worker,
# when enabled) ECS services are running and the public API answers healthy. Run automatically at
# the tail of live-finish.sh, or standalone (`make live-verify`). Non-mutating — never fires a
# check/incident (that would start an escalation execution); just describes + curls.
#
# Usage: scripts/live-verify.sh [both|staging|prod]     (default: both)
# Exit:  nonzero if any env fails a check.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/xacct.sh
. "$ROOT/scripts/lib/xacct.sh"
[ -n "${WATCH_NONPROD_ACCOUNT_ID:-}${WATCH_PROD_ACCOUNT_ID:-}" ] || { [ -f .env ] && { set -a; . ./.env; set +a; }; }
export AWS_PROFILE="${AWS_PROFILE:-watch-bootstrap}"
. "$ROOT/scripts/lib/tofu.sh"  # pinned OpenTofu (.bin/tofu, .opentofu-version)
REGION="${AWS_REGION:-us-east-1}"
ZONE="${WATCH_ZONE:-}"  # public DNS zone (from .env) — never hardcode the domain here

case "${1:-both}" in
  both) ENVS=(staging prod) ;;
  staging | prod) ENVS=("${1}") ;;
  *) echo "usage: live-verify.sh [both|staging|prod]" >&2; exit 2 ;;
esac

rc=0
for env in "${ENVS[@]}"; do
  echo "── verify $env ──"
  name="watch-$env"
  # ALB DNS read with BASE creds (management state bucket); DJANGO_ALLOWED_HOSTS=* so -k direct hit works.
  alb=$(cd "watch/$REGION/$env/app" 2>/dev/null && terragrunt output -raw alb_dns_name 2>/dev/null)
  cluster=$(cd "watch/$REGION/$env/app" 2>/dev/null && terragrunt output -raw cluster_name 2>/dev/null)

  # Service health (in the env's member account).
  #
  # runningCount ALONE IS A LIE (platform#60/#61). A service whose container exits 0 — e.g. a worker
  # whose entrypoint is a management command that no longer exists — is restarted forever by ECS,
  # which reports "has reached a steady state" between restarts. Sampling runningCount caught that
  # service as 1/1 and 0/1 minutes apart, and we shipped it green while the whole queue seam was
  # dead. The robust signal is TASK AGE: a crash-looping task is always a few seconds into its next
  # doomed attempt, so it never gets old. (rolloutState is NOT usable here — the app is CodeDeploy
  # blue/green, which reports rolloutState=None by design; only native-ECS services fill it in.)
  worker_img=$( xacct_assume "$(xacct_account_for "$env")" >/dev/null 2>&1
    export AWS_DEFAULT_REGION="$REGION"
    td=$(aws ecs describe-services --cluster "$cluster" --services "$name-worker" \
           --query 'services[0].taskDefinition' --output text 2>/dev/null)
    aws ecs describe-task-definition --task-definition "$td" \
      --query 'taskDefinition.containerDefinitions[0].image' --output text 2>/dev/null )
  counts=$( xacct_assume "$(xacct_account_for "$env")" >/dev/null 2>&1
    export AWS_DEFAULT_REGION="$REGION"
    aws ecs describe-services --cluster "$cluster" --services "$name" "$name-worker" \
      --query 'services[].[serviceName,runningCount,desiredCount]' --output text 2>/dev/null )
  app_ok=1; worker_line=""
  while read -r svc run des; do
    [ -z "$svc" ] && continue
    case "$svc" in
      # The app is CodeDeploy-managed; runningCount>=1 plus the /api/health check below IS its
      # liveness. No rolloutState to enforce.
      "$name") { [ "${run:-0}" -ge 1 ] && echo "  ✓ app service $run/$des"; } || { echo "  ✗ app service $run/$des"; app_ok=0; } ;;
      "$name-worker") worker_line="$run/$des" ;;
    esac
  done <<< "$counts"

  if [ -z "$worker_line" ]; then
    echo "  · worker service not enabled (skip)"
  elif case "$worker_img" in *:bootstrap) true ;; *) false ;; esac; then
    # Still on the placeholder image => not promoted yet. After `make live`, prod sits here until the
    # approval gate is cleared — that is not-yet-deployed, not a crash loop, so don't fail on it.
    echo "  · worker service on :bootstrap — not promoted yet (skip; approve prod to deploy)"
  else
    r="${worker_line%%/*}"
    age=$( xacct_assume "$(xacct_account_for "$env")" >/dev/null 2>&1
      export AWS_DEFAULT_REGION="$REGION"
      t=$(aws ecs list-tasks --cluster "$cluster" --family "$name-worker" --desired-status RUNNING \
            --query 'taskArns[0]' --output text 2>/dev/null)
      [ -z "$t" ] || [ "$t" = "None" ] && { echo 0; exit 0; }
      started=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$t" \
                  --query 'tasks[0].startedAt' --output text 2>/dev/null)
      [ -z "$started" ] || [ "$started" = "None" ] && { echo 0; exit 0; }
      python3 -c "import sys,datetime; s=datetime.datetime.fromisoformat('$started'); print(int((datetime.datetime.now(datetime.timezone.utc)-s).total_seconds()))" 2>/dev/null || echo 0 )

    if [ "$r" -ge 1 ] && [ "${age:-0}" -ge 60 ]; then
      echo "  ✓ worker service $worker_line (alive ${age}s on a real image — not restarting)"
    else
      echo "  ✗ worker service $worker_line (task age ${age:-0}s — on a real image but not surviving;"
      echo "    a crash-looping worker reports a healthy count between restarts. It must SURVIVE.)"
      app_ok=0
    fi
  fi

  # Public API health (no creds needed; -k since we hit the ALB name, not the cert hostname).
  if [ -n "$alb" ]; then
    body=$(curl -sk --max-time 15 "https://$alb/api/health" 2>/dev/null)
    st=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' "https://$alb/api/status" 2>/dev/null)
    case "$body" in *'"status": "ok"'*|*'"status":"ok"'*) echo "  ✓ /api/health ok" ;; *) echo "  ✗ /api/health: ${body:-no response}"; app_ok=0 ;; esac
    [ "$st" = 200 ] && echo "  ✓ /api/status 200" || { echo "  ✗ /api/status $st"; app_ok=0; }
  else
    echo "  ✗ no ALB output for $env"; app_ok=0
  fi

  # Status-page SPA (S3 + CloudFront). Hostname from the zone in .env (never hardcode the domain).
  # During the CloudFront verification hold (ADR-020) the distribution + status DNS don't exist, so
  # the host won't resolve (curl -> 000) — report as a skip, not a failure. Once deployed, enforce 200.
  if [ -z "$ZONE" ]; then
    echo "  · status page: WATCH_ZONE unset in .env (skip)"
  else
    case "$env" in staging) shost="status-stg.$ZONE" ;; *) shost="status.$ZONE" ;; esac
    scode=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' "https://$shost" 2>/dev/null)
    case "$scode" in
      200) echo "  ✓ status page ($shost) 200" ;;
      000) echo "  · status page ($shost) not deployed — CloudFront hold (skip)" ;;
      *)   echo "  ✗ status page ($shost) $scode"; app_ok=0 ;;
    esac
  fi
  [ "$app_ok" = 1 ] && echo "  → $env PASS" || { echo "  → $env FAIL"; rc=1; }
done
[ "$rc" = 0 ] && echo "live-verify: all green" || echo "live-verify: FAILURES" >&2
exit "$rc"
