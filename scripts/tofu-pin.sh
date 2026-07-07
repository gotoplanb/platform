#!/usr/bin/env bash
# Pin OpenTofu for local dev to the version in .opentofu-version, into ./.bin/tofu (gitignored).
# Idempotent — no-op if .bin/tofu is already that version. The entry scripts/Makefile default
# TG_TF_PATH to this binary, so `make live` / teardown use the pin regardless of what `tofu` on PATH is.
#
# Why pinned: OpenTofu 1.12's resource-identity check breaks cross-account *destroy* (the refresh reads
# a resource created under an assumed member-account identity and rejects the "identity change"). 1.11.x
# is the last line without it. CI pins tofu separately in its workflow, so this only covers local dev.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VER="$(tr -d ' \t\n' < .opentofu-version)"
BIN="$ROOT/.bin/tofu"

if [ -x "$BIN" ] && "$BIN" version 2>/dev/null | grep -qw "v${VER}"; then
  echo "tofu $VER already pinned at $BIN"; exit 0
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"; arch="$(uname -m)"
case "$arch" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; esac
url="https://github.com/opentofu/opentofu/releases/download/v${VER}/tofu_${VER}_${os}_${arch}.tar.gz"

echo "pinning OpenTofu $VER ($os/$arch) -> $BIN"
mkdir -p "$ROOT/.bin"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/tofu.tar.gz" "$url"
tar -xzf "$tmp/tofu.tar.gz" -C "$tmp" tofu
mv "$tmp/tofu" "$BIN"; chmod +x "$BIN"
"$BIN" version | head -1
