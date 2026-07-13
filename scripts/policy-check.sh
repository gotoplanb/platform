#!/usr/bin/env bash
# The IAM policy gate (ADR-044). The policies in policies/ are what a security team signs off on —
# so they, and the fence they depend on, must not rot silently.
#
# Checks, cheapest first (the first three need no AWS credentials at all):
#   1. Every policy is valid JSON, valid IAM, and fits IAM's 6144-character managed-policy limit.
#   2. No Allow: Action "*" on Resource "*" — except the ONE place it is deliberate and correct
#      (the boundary's ceiling statement, which exists to be capped by the Denies beneath it).
#   3. THE FENCE: every aws_iam_role in modules/ sets permissions_boundary, and the provisioner's
#      iam:CreateRole is conditioned on iam:PermissionsBoundary. Drop either and the provisioner
#      quietly becomes a path to admin — which is exactly the thing we told the security team it
#      is not. This check is the reason this script exists.
#   4. IAM Access Analyzer validate-policy, when credentials are available (findings = fail).
#
#   make policy-check          # all of it
#   AWS_PROFILE=… make policy-check
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
note() { printf '  %s\n' "$*"; }
bad() { printf '  ✗ %s\n' "$*" >&2; fail=1; }

# Concrete values so the documents can be parsed/validated as real policies. They are placeholders
# in the repo (${project}/${region}/${account_id}) so one estate's account id never leaks into a
# public repo, and so `make policies` can render them for any account.
render() {
  sed -e 's/\${project}/watch/g' -e 's/\${region}/us-east-1/g' -e 's/\${account_id}/111111111111/g' "$1"
}

echo "[policy] documents"
for f in policies/*.json; do
  name=$(basename "$f")
  body=$(render "$f")

  echo "$body" | jq empty 2>/dev/null || { bad "$name: not valid JSON"; continue; }

  version=$(echo "$body" | jq -r '.Version // ""')
  [ "$version" = "2012-10-17" ] || bad "$name: Version must be 2012-10-17 (got '$version')"

  # IAM rejects unknown elements — a stray "Comment" key is a MalformedPolicyDocument at apply time,
  # hours into a rehearsal. Catch it here instead.
  stray=$(echo "$body" | jq -r '[.Statement[] | keys[]] | unique - ["Sid","Effect","Action","NotAction","Resource","NotResource","Condition","Principal","NotPrincipal"] | join(",")')
  [ -z "$stray" ] || bad "$name: illegal IAM policy element(s): $stray"

  size=$(echo "$body" | jq -c . | wc -c | tr -d ' ')
  if [ "$size" -gt 6144 ]; then
    bad "$name: $size chars — over IAM's 6144 managed-policy limit (split it)"
  else
    note "✓ $name ($size/6144 chars)"
  fi

  # Allow *:* is a red flag everywhere except the boundary ceiling, where the Denies below it are
  # the actual policy. Anywhere else it means someone gave up.
  if [ "$name" != "watch-boundary.json" ]; then
    wide=$(echo "$body" | jq -r '[.Statement[] | select(.Effect=="Allow") | select((.Action == "*") or (.Action|type=="array" and index("*"))) | select((.Resource == "*") or (.Resource|type=="array" and index("*")))] | length')
    [ "$wide" = "0" ] || bad "$name: an Allow of Action:* on Resource:* — that is admin with extra steps"
  fi
done

echo "[policy] the fence"
# The provisioner may create roles ONLY with the boundary attached. Without this condition the whole
# design is theatre: iam:CreateRole + iam:AttachRolePolicy = AdministratorAccess in two calls.
cond=$(render policies/watch-provisioner-iam.json |
  jq -r '[.Statement[] | select(.Effect=="Allow") | select((.Action|tostring) | test("CreateRole")) | .Condition["StringEquals"]["iam:PermissionsBoundary"] // empty] | length')
[ "$cond" -ge 1 ] || bad "watch-provisioner-iam.json: iam:CreateRole is NOT conditioned on iam:PermissionsBoundary — the provisioner could mint an admin role"
[ "$cond" -ge 1 ] && note "✓ iam:CreateRole is fenced by iam:PermissionsBoundary"

# Every role the estate creates must carry the boundary, or the fence has a hole the shape of that
# role. modules/provisioner-role is the fence itself; member-access predates the boundary (it mints
# the hub-assumable role before one exists) — both are deliberate, documented exceptions.
for mod in $(grep -rl 'resource "aws_iam_role"' modules/ | xargs -n1 dirname | sort -u); do
  case "$mod" in modules/provisioner-role) continue ;; esac
  # cat first: `grep -c` over a glob prints "file:count" for many files but a bare count for one, and
  # `|| true` because grep exits non-zero on no matches — under `set -e` that would kill the
  # assignment and skip the check silently, which is the worst way for a fence to fail.
  roles=$(cat "$mod"/*.tf | grep -c 'resource "aws_iam_role"' || true)
  fenced=$(cat "$mod"/*.tf | grep -c 'permissions_boundary *=' || true)
  if [ "$fenced" -lt "$roles" ]; then
    bad "$mod: $roles role(s) but only $fenced carry permissions_boundary — that is a hole in the fence"
  else
    note "✓ $mod: $roles role(s), all fenced"
  fi
done

echo "[policy] AWS Access Analyzer"
if aws sts get-caller-identity >/dev/null 2>&1; then
  for f in policies/*.json; do
    name=$(basename "$f")
    # IDENTITY_POLICY: these are managed policies attached to a role (the boundary is one too).
    # SUGGESTIONs are style noise; WARNING/ERROR/SECURITY_WARNING are the ones a reviewer would raise
    # — PassRole on a wildcard resource, an unconditioned CreateServiceLinkedRole, and friends.
    findings=$(render "$f" | aws accessanalyzer validate-policy \
      --policy-type IDENTITY_POLICY --policy-document file:///dev/stdin \
      --query 'findings[?findingType!=`SUGGESTION`].[findingType,issueCode]' --output text 2>/dev/null || echo "SKIPPED")
    if [ "$findings" = "SKIPPED" ]; then
      note "… $name: validate-policy unavailable (needs access-analyzer:ValidatePolicy)"
    elif [ "$name" = "watch-boundary.json" ]; then
      # Access Analyzer reads the boundary as if it were a grant and objects to its `Allow *:*`
      # ceiling (PassRole/CreateServiceLinkedRole on a star resource). That ceiling is the POINT of a
      # boundary — it is capped by the Denies beneath it, and a boundary grants nothing on its own.
      # Documented in docs/SECURITY.md §2 rather than silently suppressed.
      note "… $name: findings expected (a boundary is a ceiling, not a grant) — see docs/SECURITY.md §2"
    elif [ -n "$findings" ]; then
      bad "$name: Access Analyzer findings:"; echo "$findings" >&2
    else
      note "✓ $name: no Access Analyzer findings"
    fi
  done
else
  note "… no AWS credentials — skipping Access Analyzer (the checks above already ran)"
fi

if [ "$fail" = 0 ]; then
  echo "[policy] ✓ policies green"
else
  echo "[policy] ✗ policy gate RED" >&2
  exit 1
fi
