#!/usr/bin/env bash
# Undo install.sh: hand the extensions back, then delete the app.
#
#   ./uninstall.sh                # restore VSCode as handler
#   ./uninstall.sh --to com.apple.TextEdit
#   ./uninstall.sh --keep-app     # restore associations, leave the .app in place
set -euo pipefail

APP="$HOME/Applications/NvimHere.app"
TARGET="com.microsoft.VSCode"
KEEP_APP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) TARGET="$2"; shift 2 ;;
    --keep-app) KEEP_APP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

EXTS=(
  md markdown mdx txt log
  ts tsx js jsx mjs cjs
  json jsonc yaml yml toml
  css scss sass less html
  lua py go rs rb java kt swift
  c h cpp hpp cs php sh fish
  sql vue svelte astro conf ini
)

if command -v duti >/dev/null; then
  for ext in "${EXTS[@]}"; do
    duti -s "$TARGET" "$ext" all || true
  done
  echo "associations restored to $TARGET"
fi

if [[ $KEEP_APP -eq 0 ]]; then
  rm -rf "$APP"
  echo "removed: $APP"
fi

duti -x md 2>/dev/null || true
