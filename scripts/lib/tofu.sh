# Resolve OpenTofu for Terragrunt (sourced by the entry scripts; expects $ROOT set).
#
# Prefer the repo-pinned binary (.bin/tofu, version in .opentofu-version) over whatever `tofu` is on
# PATH — local `tofu` drifts via brew, and OpenTofu 1.12's resource-identity check breaks cross-account
# destroy (see scripts/tofu-pin.sh). Auto-pins on first use (idempotent download). Respects an
# explicit TG_TF_PATH if the caller already set one. CI pins tofu in its workflow, not here.
if [ -z "${TG_TF_PATH:-}" ]; then
  if [ ! -x "$ROOT/.bin/tofu" ] && [ -f "$ROOT/.opentofu-version" ]; then
    bash "$ROOT/scripts/tofu-pin.sh" >&2 || true
  fi
  if [ -x "$ROOT/.bin/tofu" ]; then TG_TF_PATH="$ROOT/.bin/tofu"; else TG_TF_PATH="tofu"; fi
fi
export TG_TF_PATH
