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
export TG_TF_PATH="${TG_TF_PATH:-tofu}"
export AWS_PROFILE="${AWS_PROFILE:-watch-bootstrap}"
REGION="${AWS_REGION:-us-east-1}"
BASE="watch/$REGION"
REPO=watch

# prod/dns reads CLOUDFLARE_API_TOKEN; load it from .env (never committed) if not already set.
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] && [ -f .env ]; then set -a; . ./.env; set +a; fi

WHICH="${1:-both}"; [ $# -gt 0 ] && shift
ASSUME_YES=0
for a in "$@"; do case "$a" in -y|--yes) ASSUME_YES=1 ;; *) echo "unknown flag: $a" >&2; exit 2 ;; esac; done

case "$WHICH" in
  staging) DIR="$BASE/staging" ;;
  prod)    DIR="$BASE/prod" ;;
  both)    DIR="$BASE" ;;               # ecr + staging + prod + prod/dns + pipeline
  *) echo "usage: create.sh [staging|prod|both] [-y]" >&2; exit 2 ;;
esac

echo "Profile : $AWS_PROFILE"
aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || { echo "no AWS creds for $AWS_PROFILE" >&2; exit 1; }
echo "Region  : $REGION"
echo "Scope   : $WHICH  ($DIR)"
[ -z "${CLOUDFLARE_API_TOKEN:-}" ] && echo "WARN    : CLOUDFLARE_API_TOKEN unset — prod/dns will fail (set it or source .env)"

# --- ensure a :bootstrap image exists (the app task-def pulls <repo>:bootstrap) ---
if aws ecr describe-images --region "$REGION" --repository-name "$REPO" \
     --query 'imageDetails[?contains(imageTags,`bootstrap`)]' --output text 2>/dev/null | grep -q .; then
  echo "Bootstrap: :bootstrap image present."
else
  NEWEST=$(aws ecr describe-images --region "$REGION" --repository-name "$REPO" \
     --query 'reverse(sort_by(imageDetails,&imagePushedAt))[0].imageTags[0]' --output text 2>/dev/null)
  if [ -z "$NEWEST" ] || [ "$NEWEST" = "None" ]; then
    echo "ERROR: ECR repo '$REPO' has no images to seed :bootstrap — build+push one first." >&2; exit 1
  fi
  echo "Bootstrap: seeding :bootstrap from newest image ($NEWEST)..."
  MANIFEST=$(aws ecr batch-get-image --region "$REGION" --repository-name "$REPO" \
     --image-ids imageTag="$NEWEST" --query 'images[0].imageManifest' --output text)
  aws ecr put-image --region "$REGION" --repository-name "$REPO" \
     --image-tag bootstrap --image-manifest "$MANIFEST" >/dev/null
  echo "  :bootstrap -> $NEWEST"
fi

if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Apply $WHICH now? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
fi

echo "==================== APPLY $DIR ===================="
( cd "$DIR" && terragrunt run --all apply --non-interactive ); rc=$?

echo "==================== SUMMARY ===================="
if [ "$rc" -ne 0 ]; then echo "apply failed (rc=$rc) — inspect above; re-run is idempotent"; exit "$rc"; fi
echo "create complete ($WHICH)."
[ "$WHICH" != staging ] && echo "prod live: https://watch.davestanton.com  https://status.davestanton.com"
echo "Next: push code through the pipeline to promote a fresh build (CodeDeploy shifts off :bootstrap)."
