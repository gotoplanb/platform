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
#   scripts/teardown.sh                  # both envs + pipeline (default), sequential
#   scripts/teardown.sh both --parallel  # pipeline first, then staging & prod concurrently
#   scripts/teardown.sh staging          # staging only (leaves prod + pipeline up)
#   scripts/teardown.sh prod             # prod only
#   scripts/teardown.sh both --with-dns  # also destroy prod/dns (cert + Cloudflare records)
#   scripts/teardown.sh both -y          # skip the confirm prompt (automation)
#
# Cross-env parallelism is safe: staging and prod are disjoint (separate VPCs/RDS/ALB/CF
# and separate TF state keys), and the only shared stack — pipeline — is destroyed first,
# before the env fan-out. Within an env, stacks always go sequentially (dependents-first).
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

# prod/dns's CNAME cleanup (below) drives the cloudflare provider; load its token from .env.
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] && [ -f .env ]; then set -a; . ./.env; set +a; fi

# dependents -> dependencies (the order we destroy within an env). Each stack must be destroyed
# before the stacks it depends on (dependency blocks only mock for validate/plan, not destroy).
# Telemetry plane (#19/#29): app + obs/tempo depend on gateway; obs/grafana depends on obs/tempo;
# gateway/tempo depend on network. Prod has only `gateway` (Grafana Cloud, no slice) — the missing
# obs/* dirs SKIP cleanly. Order: grafana -> tempo -> app -> gateway -> ... -> network.
ENV_STACKS=(observability frontend intake escalation obs/grafana obs/tempo app gateway config data network)

WHICH="${1:-both}"; [ $# -gt 0 ] && shift
WITH_DNS=0; ASSUME_YES=0; PARALLEL=0
for a in "$@"; do
  case "$a" in
    --with-dns)  WITH_DNS=1 ;;
    --parallel)  PARALLEL=1 ;;
    -y|--yes)    ASSUME_YES=1 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

case "$WHICH" in
  staging) ENVS=(staging); DO_PIPELINE=0 ;;
  prod)    ENVS=(prod);    DO_PIPELINE=0 ;;
  both)    ENVS=(staging prod); DO_PIPELINE=1 ;;
  *) echo "usage: teardown.sh [staging|prod|both] [--parallel] [--with-dns] [-y]" >&2; exit 2 ;;
esac

RESDIR="$(mktemp -d "${TMPDIR:-/tmp}/watch-teardown.XXXXXX")"
RESULTS="$RESDIR/results"; : > "$RESULTS"

# stacks_for_env <env> -> prints destroy-ordered dirs (dns appended only for prod+--with-dns)
stacks_for_env() {
  local e="$1" s
  for s in "${ENV_STACKS[@]}"; do echo "$BASE/$e/$s"; done
  # prod's DNS is split (ADR-020): dns-status (CloudFront record) then dns (API record).
  { [ "$WITH_DNS" = 1 ] && [ "$e" = prod ]; } && { echo "$BASE/prod/dns-status"; echo "$BASE/prod/dns"; }
}

# destroy_one <dir> — single stack; records OK/FAIL/SKIP (one $RESULTS line, append is atomic)
destroy_one() {
  local dir="$1"
  echo "==================== DESTROY $dir ===================="
  if [ ! -f "$dir/terragrunt.hcl" ]; then echo "SKIP   $dir (no stack)" >> "$RESULTS"; return; fi
  if ( cd "$dir" && terragrunt destroy -auto-approve --non-interactive ); then
    echo "OK     $dir" >> "$RESULTS"
  else
    echo "FAIL   $dir" >> "$RESULTS"
  fi
}

# destroy_env <env> — that env's stacks, strictly sequential (dependents-first)
destroy_env() {
  local e="$1" d
  while read -r d; do destroy_one "$d"; done < <(stacks_for_env "$e")
}

echo "Profile : $AWS_PROFILE"
aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || { echo "no AWS creds for $AWS_PROFILE" >&2; exit 1; }
echo "Region  : $REGION"
echo "Envs    : ${ENVS[*]}$([ "$DO_PIPELINE" = 1 ] && echo ' (+ pipeline first)')"
echo "Mode    : $([ "$PARALLEL" = 1 ] && [ "${#ENVS[@]}" -gt 1 ] && echo 'parallel (per-env)' || echo sequential)"
echo "Kept    : state backend, ecr, connection, ci-trigger, account/*, github/*$([ "$WITH_DNS" = 1 ] && echo '' || echo ', prod/dns')"

if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
fi

# The watch/status CNAMEs point at the ALB/CloudFront we're about to destroy. Remove just
# those two records (keep the ACM cert + validation records — slow to revalidate) so a later
# create is clean; otherwise CloudFront refuses to re-claim status.* (CNAMEAlreadyExists).
# _drop_records <label> <dir> <target...> — targeted destroy of a stack's CNAME record(s), but
# ONLY if the stack has such state. A split record stack that never applied (e.g. prod/dns-status
# while CloudFront is held) has none — skip it rather than fail the whole run (exit 1).
_drop_records() {
  local label="$1" dir="$2"; shift 2
  [ -f "$dir/terragrunt.hcl" ] || return 0
  if ! ( cd "$dir" && terragrunt state list 2>/dev/null | grep -q cloudflare_record ); then
    echo "SKIP   $label (no records in state)" >> "$RESULTS"; return 0
  fi
  local targets=() t
  for t in "$@"; do targets+=("-target=$t"); done
  if ( cd "$dir" && terragrunt destroy "${targets[@]}" -auto-approve --non-interactive ); then
    echo "OK     $label" >> "$RESULTS"
  else
    echo "FAIL   $label" >> "$RESULTS"
  fi
}

destroy_dns_records() { # $1 = env — drops the app/status CNAMEs, keeps the ACM cert
  local e="$1" d="$BASE/$1/dns" ds="$BASE/$1/dns-status"
  { [ -f "$d/terragrunt.hcl" ] || [ -f "$ds/terragrunt.hcl" ]; } || return 0
  echo "==================== DROP $e CNAME records (keep cert) ===================="
  if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then echo "SKIP   $e dns records (CLOUDFLARE_API_TOKEN unset)" >> "$RESULTS"; return 0; fi
  # The app record (and status too, for envs that keep both in one stack e.g. staging) live in
  # $e/dns; prod's status record is split into $e/dns-status (ADR-020). -target matches all count
  # indices and is a no-op for a record this stack doesn't own.
  _drop_records "$e/dns records" "$d" cloudflare_record.app cloudflare_record.status
  _drop_records "$e/dns-status record" "$ds" cloudflare_record.status
}

# pipeline is shared and references both envs — always destroy it first, synchronously.
[ "$DO_PIPELINE" = 1 ] && destroy_one "$BASE/pipeline"

# drop each in-scope env's app/status CNAMEs before tearing that env down (keeps its cert)
for e in "${ENVS[@]}"; do destroy_dns_records "$e"; done

if [ "$PARALLEL" = 1 ] && [ "${#ENVS[@]}" -gt 1 ]; then
  pids=()
  for e in "${ENVS[@]}"; do
    destroy_env "$e" > "$RESDIR/$e.log" 2>&1 &
    pids+=("$!")
    echo "  $e teardown running in background -> $RESDIR/$e.log (pid $!)"
  done
  echo "  (tail -f the logs above to watch; waiting for both to finish...)"
  fail=0; for p in "${pids[@]}"; do wait "$p" || fail=1; done
else
  for e in "${ENVS[@]}"; do destroy_env "$e"; done
fi

echo "==================== SUMMARY ===================="
sort "$RESULTS"
echo "logs: $RESDIR"
if grep -q '^FAIL' "$RESULTS"; then
  echo "one or more stacks failed — re-run or inspect the logs above"
  exit 1
fi
echo "teardown complete. Run scripts/sweep.sh to confirm no billable orphans remain."
