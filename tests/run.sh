#!/bin/bash
# Runs every suite under both bashes, then the linter.
#
#   bash tests/run.sh
#
# Exit status: 0 everything green, 1 otherwise.

set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
status=0

for bash_bin in /bin/bash /opt/homebrew/bin/bash; do
  if [[ ! -x $bash_bin ]]; then
    echo "skip (missing): $bash_bin"
    continue
  fi
  echo "== $("$bash_bin" --version | head -1)"
  BASH_BIN=$bash_bin "$bash_bin" "$HERE/template.sh" || status=1
  BASH_BIN=$bash_bin "$bash_bin" "$HERE/plan.sh" || status=1
  BASH_BIN=$bash_bin "$bash_bin" "$HERE/actions.sh" || status=1
  BASH_BIN=$bash_bin "$bash_bin" "$HERE/quoting.sh" || status=1
  BASH_BIN=$bash_bin "$bash_bin" "$HERE/forward.sh" || status=1
done

echo "== golden"
bash "$HERE/golden.sh" check || status=1

echo "== shellcheck"
if command -v shellcheck >/dev/null; then
  shellcheck -x "$REPO/bin/cli-here" "$HERE"/*.sh || status=1
else
  echo "shellcheck not installed, skipped"
fi

if [[ $status -ne 0 ]]; then
  echo "FAILED"
else
  echo "all suites pass"
fi
exit $status
