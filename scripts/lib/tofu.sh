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

# Assert the resolved tofu matches the pin (#46). A silent brew bump to 1.12 broke cross-account
# teardown after ~100 clean runs; nothing caught it. Hard-fail on mismatch so a drifted toolchain
# can't run a mutating command. Set TOFU_PIN_SOFT=1 to downgrade to a warning (read-only/plan use).
if [ -f "$ROOT/.opentofu-version" ]; then
  _want="$(tr -d ' \t\n' < "$ROOT/.opentofu-version")"
  _have="$("$TG_TF_PATH" version 2>/dev/null | sed -n 's/^OpenTofu v//p' | head -1)"
  if [ -n "$_want" ] && [ "$_have" != "$_want" ]; then
    if [ "${TOFU_PIN_SOFT:-0}" = 1 ]; then
      echo "WARN    : OpenTofu $_have != pinned $_want ($TG_TF_PATH) — run scripts/tofu-pin.sh" >&2
    else
      echo "FATAL   : OpenTofu $_have != pinned $_want ($TG_TF_PATH). Run 'make tofu-pin' (or set" >&2
      echo "          TOFU_PIN_SOFT=1 for read-only use). Refusing to run on a drifted toolchain." >&2
      exit 1
    fi
  fi
fi
