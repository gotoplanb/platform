#!/usr/bin/env bash
# Package the Django Lambda bundle (intake consumer + escalation handlers) from the watch repo and
# promote it to an env's functions — the LOCAL stand-in for the pipeline's buildspec Lambda step,
# needed only while CodeBuild is on hold (ADR-020). Same zip the buildspec builds: slim deps as
# linux wheels + backend/config + backend/incidents + the handler modules. Cross-account per env.
#
# Usage: scripts/lambda-promote.sh [staging|prod|both]   (default: staging)
# Env:   WATCH_REPO (default ../watch), AWS_PROFILE (default watch-bootstrap), AWS_REGION.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/xacct.sh
. "$ROOT/scripts/lib/xacct.sh"
[ -n "${WATCH_NONPROD_ACCOUNT_ID:-}${WATCH_PROD_ACCOUNT_ID:-}" ] || { [ -f .env ] && { set -a; . ./.env; set +a; }; }
export AWS_PROFILE="${AWS_PROFILE:-watch-bootstrap}"
REGION="${AWS_REGION:-us-east-1}"
WATCH_REPO="${WATCH_REPO:-$ROOT/../watch}"
FUNCTIONS=(record-token commit intake-consumer)

case "${1:-staging}" in
  both) ENVS=(staging prod) ;;
  staging | prod) ENVS=("${1:-staging}") ;;
  *) echo "usage: lambda-promote.sh [staging|prod|both]" >&2; exit 2 ;;
esac

[ -d "$WATCH_REPO/backend" ] || { echo "watch repo not found at $WATCH_REPO (set WATCH_REPO)" >&2; exit 1; }

# Resolve a Python 3.12 with a modern pip — bare `python3` may be Xcode's old build (pip 21.x),
# which mishandles --python-version/--platform. Prefer the watch venv, then python3.12 on PATH.
PY=""
for c in "$WATCH_REPO/backend/.venv/bin/python" "$WATCH_REPO/.venv/bin/python" python3.12; do
  if [ -x "$c" ] || command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "need Python 3.12 (watch venv at $WATCH_REPO/backend/.venv, or python3.12 on PATH)" >&2; exit 1; }

# --- package once (linux wheels so psycopg[binary] matches the Lambda runtime) ---
BUILD="$(mktemp -d)"; ZIP="$BUILD/lambda.zip"
echo "Packaging Lambda bundle from $WATCH_REPO (python: $PY) ..."
"$PY" -m pip install --quiet \
  --platform manylinux2014_x86_64 --implementation cp --python-version 3.12 --only-binary=:all: \
  --target "$BUILD/pkg" -r "$WATCH_REPO/escalation/lambdas/requirements.txt" || { echo "pip package failed" >&2; exit 1; }
cp -r "$WATCH_REPO/backend/config" "$WATCH_REPO/backend/incidents" "$BUILD/pkg/"
cp "$WATCH_REPO"/escalation/lambdas/{record_token,commit,_bootstrap,intake_consumer}.py "$BUILD/pkg/"
( cd "$BUILD/pkg" && zip -qr "$ZIP" . )
echo "  -> $(du -h "$ZIP" | cut -f1)"

# --- promote per env (each env's functions live in its member account) ---
rc=0
for env in "${ENVS[@]}"; do
  echo "Promoting to $env ($(xacct_account_for "$env")) ..."
  ( xacct_assume "$(xacct_account_for "$env")"
    export AWS_DEFAULT_REGION="$REGION"
    for fn in "${FUNCTIONS[@]}"; do
      aws lambda update-function-code --function-name "watch-${env}-${fn}" \
        --zip-file "fileb://$ZIP" --publish --query 'FunctionName' --output text >/dev/null \
        && echo "  ✓ watch-${env}-${fn}" || { echo "  ✗ watch-${env}-${fn}"; exit 1; }
    done
  ) || rc=1
done
rm -rf "$BUILD"
[ "$rc" = 0 ] && echo "lambda-promote OK (${ENVS[*]})" || echo "lambda-promote had failures" >&2
exit "$rc"
