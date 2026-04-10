#!/usr/bin/env bash
set -euo pipefail

# Make *.sh files runnable everywhere (Linux shells) by normalizing CRLF -> LF.
# Safe to run multiple times (idempotent).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_sedi() {
  # Works on GNU sed and BSD sed.
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"
  else
    # BSD sed (macOS)
    sed -i '' "$@"
  fi
}

normalize_glob() {
  local pattern="$1"
  local f
  shopt -s nullglob
  for f in $pattern; do
    [ -f "$f" ] || continue
    _sedi 's/\r$//' "$f" || true
  done
  shopt -u nullglob
}

normalize_glob "$ROOT_DIR/k8s/scripts/"'*.sh'
normalize_glob "$ROOT_DIR/terraform/scripts/"'*.sh'
normalize_glob "$ROOT_DIR/scripts/"'*.sh'

echo "Normalized CRLF->LF for shell scripts under k8s/scripts, terraform/scripts, scripts."

