#!/usr/bin/env bash
# Deterministic teardown of Watch's per-env AWS stacks (ADR-015/019: prod + ephemeral
# staging). Destroys stacks dependents-first so nothing blocks on a live dependency.
#
# KEEPS the ~$0 foundation by default — only the hourly-billed per-env stacks (and the
# shared pipeline, on `both`) are destroyed:
#   kept: state backend (watch-tfstate-*/watch-tflocks), ecr (the built image),
#         prod/dns (ACM cert + Cloudflare records — free, slow to revalidate),
#         account/* (budget, github-oidc), github/* (repo config).
#
# Usage:
#   scripts/teardown.sh                  # both envs + pipeline (default)
#   scripts/teardown.sh staging          # staging only (leaves prod + pipeline up)
#   scripts/teardown.sh prod             # prod only
#   scripts/teardown.sh both --with-dns  # also destroy prod/dns (cert + records)
#   scripts/teardown.sh both -y          # skip the confirm prompt (automation)
#
# Env: AWS_PROFILE (default watch-bootstrap — needs write), AWS_REGION (default us-east-1),
#      TG_TF_PATH (default tofu). Continue-on-error; prints a summary; exits nonzero if any
#      stack failed so a caller can react. Re-run is safe (already-destroyed = no-op).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export TG_TF_PATH="${TG_TF_PATH:-tofu}"
export AWS_PROFILE="${AWS_PROFILE:-watch-bootstrap}"
REGION="${AWS_REGION:-us-east-1}"
BASE="watch/$REGION"

# dependents -> dependencies (the order we destroy within an env)
ENV_STACKS=(observability frontend intake escalation app config data network)

WHICH="${1:-both}"; [ $# -gt 0 ] && shift
WITH_DNS=0; ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --with-dns) WITH_DNS=1 ;;
    -y|--yes)   ASSUME_YES=1 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

case "$WHICH" in
  staging) ENVS=(staging); DO_PIPELINE=0 ;;
  prod)    ENVS=(prod);    DO_PIPELINE=0 ;;
  both)    ENVS=(staging prod); DO_PIPELINE=1 ;;
  *) echo "usage: teardown.sh [staging|prod|both] [--with-dns] [-y]" >&2; exit 2 ;;
esac

# Build the ordered destroy list.
TARGETS=()
[ "$DO_PIPELINE" = 1 ] && TARGETS+=("$BASE/pipeline")   # shared; references both envs
for e in "${ENVS[@]}"; do
  for s in "${ENV_STACKS[@]}"; do TARGETS+=("$BASE/$e/$s"); done
done
# prod/dns is a leaf (app/frontend reach the cert via a data source, not a dependency),
# so it's safe to destroy last — only when explicitly asked.
if [ "$WITH_DNS" = 1 ]; then
  for e in "${ENVS[@]}"; do [ "$e" = prod ] && TARGETS+=("$BASE/prod/dns"); done
fi

echo "Profile : $AWS_PROFILE"
aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || { echo "no AWS creds for $AWS_PROFILE" >&2; exit 1; }
echo "Region  : $REGION"
echo "Will destroy, in order:"; printf '  %s\n' "${TARGETS[@]}"
echo "Kept    : state backend, ecr, account/*, github/*$([ "$WITH_DNS" = 1 ] && echo '' || echo ', prod/dns')"

if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
fi

declare -a RESULTS=()
for dir in "${TARGETS[@]}"; do
  echo "==================== DESTROY $dir ===================="
  if [ ! -f "$dir/terragrunt.hcl" ]; then RESULTS+=("SKIP   $dir (no stack)"); continue; fi
  if ( cd "$dir" && terragrunt destroy -auto-approve --non-interactive ); then
    RESULTS+=("OK     $dir")
  else
    RESULTS+=("FAIL   $dir")
  fi
done

echo "==================== SUMMARY ===================="
printf '%s\n' "${RESULTS[@]}"
printf '%s\n' "${RESULTS[@]}" | grep -q '^FAIL' && { echo "one or more stacks failed — re-run or inspect"; exit 1; }
echo "teardown complete. Run scripts/sweep.sh to confirm no billable orphans remain."
