#!/usr/bin/env bash
# Render the policy documents concrete, for handing to a security team (ADR-044).
#
# The documents in policies/ carry ${project}/${region}/${account_id} placeholders — so no estate's
# account id sits in a public repo, and so the same documents serve every deployment. This renders
# them for YOUR account, which is what a reviewer actually wants to read: real ARNs, no templating,
# nothing to take on faith.
#
#   make policies                      # renders for the current AWS identity's account
#   ACCOUNT_ID=123456789012 make policies
#   OUT=/tmp/handover make policies    # write files instead of printing
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

PROJECT="${WATCH_PROJECT:-watch}"
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)}"

if [ -z "$ACCOUNT_ID" ]; then
  echo "No account id: pass ACCOUNT_ID=… or set AWS credentials (the ARNs must be concrete to be reviewable)." >&2
  exit 2
fi

render() {
  sed -e "s/\${project}/$PROJECT/g" -e "s/\${region}/$REGION/g" -e "s/\${account_id}/$ACCOUNT_ID/g" "$1"
}

if [ -n "${OUT:-}" ]; then
  mkdir -p "$OUT"
  for f in policies/*.json; do render "$f" >"$OUT/$(basename "$f")"; done
  echo "Rendered $(ls policies/*.json | wc -l | tr -d ' ') policies for account $ACCOUNT_ID → $OUT"
  echo "Hand these to the security team alongside docs/SECURITY.md."
else
  for f in policies/*.json; do
    echo "───────────────────────────── $(basename "$f")"
    render "$f"
  done
fi
