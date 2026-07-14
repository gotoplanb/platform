#!/usr/bin/env bash
# FIRST-RUN STEP (ADR-047). Build the app image from source and push it as <repo>:bootstrap.
#
# Run this ONCE, before the first `make live` in a fresh account. It is deliberately outside the
# tofu apply, in the same spirit as the one admin step that mints the provisioner (docs/SECURITY.md
# §5): some things genuinely cannot be a resource graph, and pretending otherwise is how you get a
# system that only works if it is already working.
#
# WHY THIS EXISTS. The ECS task definitions point at `<repo>:bootstrap` — an image that must exist
# before the services can start, but which the pipeline can only produce AFTER the estate exists.
# That is a real chicken-and-egg, and it used to be papered over: create.sh "self-healed" a missing
# :bootstrap tag by re-tagging whatever image happened to be NEWEST in the repo. In a long-lived
# estate that is some build from days ago, so a fresh estate came up running STALE CODE — and every
# ordering bug we chased followed from it:
#
#   * migrations ran against old code, so the schema lagged the Lambdas (platform#62 — the deploy
#     gate then blocked the deploy that would have fixed it);
#   * the worker's entrypoint (`manage.py run_sqs_worker`) did not exist in the old image, so it
#     exited 0 forever while ECS reported "steady state" (platform#61/#60).
#
# And on a genuinely EMPTY repo — an adopter's first run — create.sh simply failed with "build+push
# one first". The manual step was always there. This makes it explicit, and makes it push the code
# you are actually deploying.
#
# Usage:  scripts/bootstrap-image.sh [--app-dir DIR]      (default: $WATCH_APP_DIR, else ../watch)
# Env:    AWS_PROFILE, AWS_REGION, WATCH_PROJECT
set -euo pipefail
cd "$(dirname "$0")/.."

APP_DIR="${WATCH_APP_DIR:-../watch}"
while [ $# -gt 0 ]; do
  case "$1" in
    --app-dir) APP_DIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

export AWS_PROFILE="${AWS_PROFILE:-watch-bootstrap}"
REGION="${AWS_REGION:-us-east-1}"
PROJECT="${WATCH_PROJECT:-watch}"

[ -f .env ] && { set -a; . ./.env; set +a; }
# shellcheck source=lib/xacct.sh
. scripts/lib/xacct.sh

[ -f "$APP_DIR/Dockerfile" ] || {
  echo "ERROR: no Dockerfile in $APP_DIR — point at the app repo with --app-dir or WATCH_APP_DIR." >&2
  exit 1
}

# The ECR repo lives in the foundation account (nonprod when the members are split; this account
# otherwise). Assume in for the raw ECR calls, exactly as create.sh does.
xacct_assume "$(xacct_account_for foundation)" >/dev/null

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REPO_URL="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${PROJECT}"

echo "Building ${PROJECT}:bootstrap from ${APP_DIR}"
echo "  → ${REPO_URL}"

aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com" >/dev/null

# linux/amd64 explicitly: Fargate runs amd64, and an arm64 image built on an Apple laptop starts,
# fails to exec, and is reported by ECS as a task that stopped — which looks exactly like a crash
# loop and costs an hour to diagnose.
docker build --platform linux/amd64 -t "${REPO_URL}:bootstrap" "$APP_DIR"
docker push "${REPO_URL}:bootstrap"

DIGEST=$(aws ecr describe-images --region "$REGION" --repository-name "$PROJECT" \
  --image-ids imageTag=bootstrap --query 'imageDetails[0].imageDigest' --output text)
echo "OK — ${PROJECT}:bootstrap = ${DIGEST}"
echo 'The estate will now come up on THIS code. Run `make live` next.'
