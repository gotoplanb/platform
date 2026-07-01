#!/usr/bin/env bash
# Deploy the status-page SPA to the frontend bucket + invalidate CloudFront. Terraform builds
# the bucket/distribution but not its contents, so a fresh create.sh leaves the status page
# empty (CloudFront 403). This is that missing step, codified (platform#25).
#
# Stages the build-less React page (watch repo frontend/), rewrites window.WATCH_API to the
# env's API origin (the page fetches the API cross-origin, CORS), s3-syncs, and invalidates.
#
# Usage:
#   scripts/deploy-frontend.sh [prod|staging]
# Env: AWS_PROFILE (default watch-bootstrap), AWS_REGION (us-east-1), TG_TF_PATH (tofu),
#      FRONTEND_SRC (default ~/watch/frontend), API_ORIGIN (default per-env below).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export TG_TF_PATH="${TG_TF_PATH:-tofu}"
export AWS_PROFILE="${AWS_PROFILE:-watch-bootstrap}"
REGION="${AWS_REGION:-us-east-1}"
BASE="watch/$REGION"
FRONTEND_SRC="${FRONTEND_SRC:-$HOME/watch/frontend}"

ENV="${1:-prod}"
case "$ENV" in
  prod)    API_ORIGIN="${API_ORIGIN:-https://watch.davestanton.com}" ;;
  staging) API_ORIGIN="${API_ORIGIN:-https://watch-stg.davestanton.com}" ;; # #34: staging now has HTTPS
  *) echo "usage: deploy-frontend.sh [prod|staging]" >&2; exit 2 ;;
esac
[ -d "$FRONTEND_SRC" ] || { echo "frontend source not found: $FRONTEND_SRC" >&2; exit 1; }
[ -n "$API_ORIGIN" ] || { echo "no API_ORIGIN for $ENV — set API_ORIGIN=... (staging ALB has no HTTPS)" >&2; exit 1; }

echo "Resolving $ENV/frontend outputs..."
BUCKET=$(cd "$BASE/$ENV/frontend" && terragrunt output -raw bucket_name 2>/dev/null)
DIST=$(cd "$BASE/$ENV/frontend"   && terragrunt output -raw distribution_id 2>/dev/null)
[ -n "$BUCKET" ] && [ -n "$DIST" ] || { echo "could not read bucket/distribution outputs" >&2; exit 1; }
echo "  bucket=$BUCKET  distribution=$DIST  api=$API_ORIGIN"

# Stage: copy the page and pin WATCH_API to this env's API origin (dev default is :8010).
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/watch-frontend.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp -R "$FRONTEND_SRC/." "$STAGE/"
rm -f "$STAGE/README.md"
sed -i '' "s|window.WATCH_API = .*;|window.WATCH_API = \"$API_ORIGIN\";|" "$STAGE/index.html"
grep -q "window.WATCH_API = \"$API_ORIGIN\"" "$STAGE/index.html" || { echo "WATCH_API rewrite failed" >&2; exit 1; }

echo "Syncing to s3://$BUCKET ..."
aws s3 sync "$STAGE/" "s3://$BUCKET/" --delete --region "$REGION"
echo "Invalidating CloudFront $DIST ..."
INV=$(aws cloudfront create-invalidation --distribution-id "$DIST" --paths '/*' \
        --query 'Invalidation.Id' --output text)
echo "  invalidation $INV created"
echo "OK — status page deployed for $ENV (allow a moment for the invalidation to complete)."
