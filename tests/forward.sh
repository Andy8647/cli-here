#!/bin/bash
# The app's forwarding layer, without building or installing a bundle.
#
# src/NvimHere.applescript is compiled with the four placeholders pointed at
# stubs, then driven through `load script` so the real `open` / `run` handlers
# run. The stub records the argv it was handed and the PATH / EDITOR it saw.
#
# One substitution is test-only: the `display alert` is swapped for `log`, so
# the failure branch can be checked without a dialog appearing. Whether that
# alert is visible on screen is a manual check.
#
#   /bin/bash tests/forward.sh
#
# Exit status: 0 all cases match, 1 otherwise.

set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
TEMPLATE=$REPO/src/NvimHere.applescript

FAILED=0

ROOT=$(cd "$(mktemp -d -t cli-here-forward)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
STUB=$ROOT/stub
HOME_FAKE=$ROOT/home
WORK=$ROOT/work
CLI_OUT=$ROOT/cli-argv
NVIM_OUT=$ROOT/nvim-argv
ENV_OUT=$ROOT/env
LOG=$HOME_FAKE/Library/Logs/NvimHere.log
FULL_LOG=$ROOT/full-log
mkdir -p "$STUB" "$HOME_FAKE/Library/Logs" "$WORK"

printf 'one\n' >"$WORK/a.md"
printf 'two\n' >"$WORK/b.py"

# Both stubs record the argv and the environment do shell script handed them.
cat >"$STUB/record" <<'STUB'
#!/bin/bash
case ${0##*/} in
  stub-nvim-here) out=${CLI_HERE_FORWARD_NVIM:-} ;;
  *) out=${CLI_HERE_FORWARD_OUT:-} ;;
esac
{
  for a in "$@"; do printf '%s\0' "$a"; done
} >"$out"
{
  printf 'PATH=%s\n' "$PATH"
  printf 'EDITOR=%s\n' "$EDITOR"
  printf 'HOME=%s\n' "$HOME"
} >"$CLI_HERE_FORWARD_ENV"
if [[ -n ${CLI_HERE_FORWARD_FAIL:-} ]]; then
  printf '%s\n' "$CLI_HERE_FORWARD_FAIL" >&2
  exit 3
fi
exit 0
STUB
chmod +x "$STUB/record"
ln -s record "$STUB/stub-cli-here"
ln -s record "$STUB/stub-nvim-here"

# Substitute the placeholders. | as the delimiter; nothing here contains it.
sed -e "s|__CLI_HERE__|$STUB/stub-cli-here|g" \
  -e "s|__NVIM_HERE__|$STUB/stub-nvim-here|g" \
  -e "s|__PATH__|/fake/bin:/usr/bin:/bin|g" \
  -e "s|__EDITOR__|fake-editor|g" \
  -e 's|display alert "NvimHere" message errMsg as warning|log "ALERT: " \& errMsg|' \
  "$TEMPLATE" >"$ROOT/app.applescript"

if ! osacompile -o "$ROOT/app.scpt" "$ROOT/app.applescript" 2>"$ROOT/compile.err"; then
  echo "FAIL: the template does not compile" >&2
  cat "$ROOT/compile.err" >&2
  exit 1
fi

cat >"$ROOT/driver.applescript" <<'DRIVER'
on run argv
	set target to load script (POSIX file (item 1 of argv))
	set mode to item 2 of argv
	if mode is "open" then
		set fs to {}
		repeat with i from 3 to (count of argv)
			set end of fs to (POSIX file (item i of argv)) as alias
		end repeat
		tell target to open fs
	else
		tell target to run
	end if
end run
DRIVER
osacompile -o "$ROOT/driver.scpt" "$ROOT/driver.applescript"

drive() { # drive MODE ARGS... ; fills CODE / STDERR
  : >"$CLI_OUT"
  : >"$NVIM_OUT"
  : >"$ENV_OUT"
  : >"$FULL_LOG"
  CLI_HERE_FORWARD_OUT=$CLI_OUT CLI_HERE_FORWARD_NVIM=$NVIM_OUT \
    CLI_HERE_FORWARD_ENV=$ENV_OUT \
    HOME="$HOME_FAKE" osascript "$ROOT/driver.scpt" "$ROOT/app.scpt" "$@" \
    >"$ROOT/out" 2>"$ROOT/err"
  CODE=$?
}

nulldump() {
  local a out=""
  if [[ -s $1 ]]; then
    while IFS= read -r -d '' a; do out+="$a|"; done <"$1"
  fi
  printf '%s' "$out"
}

norm() {
  local s
  s=$(cat)
  s=${s//"$WORK"/<W>}
  s=${s//"$STUB"/<S>}
  s=${s//"$HOME_FAKE"/<H>}
  printf '%s' "$s"
}

t() {
  if [[ $2 == "$3" ]]; then
    echo "ok   [$1]"
  else
    echo "FAIL [$1]" >&2
    echo "  expected: $2" >&2
    echo "  actual:   $3" >&2
    FAILED=1
  fi
}

# --- open: files handed over, --from-ls added, env injected ---------------
drive open "$WORK/a.md" "$WORK/b.py"
t open/exit 0 "$CODE"
t open/argv "--from-ls|--|<W>/a.md|<W>/b.py|" "$(nulldump "$CLI_OUT" | norm)"
t open/env $'PATH=/fake/bin:/usr/bin:/bin\nEDITOR=fake-editor\nHOME=<H>' \
  "$(norm <"$ENV_OUT")"
t open/nothing-for-nvim "" "$(nulldump "$NVIM_OUT")"

# --- run: a double-click opens nvim, and never reads the rule table -------
drive run
t run/exit 0 "$CODE"
t run/argv "--|" "$(nulldump "$NVIM_OUT" | norm)"
t run/nothing-for-cli "" "$(nulldump "$CLI_OUT")"

# --- failure: stderr becomes the message, the exit code goes to the log ---
CLI_HERE_FORWARD_FAIL="cli-here: rules are broken" \
  CLI_HERE_FORWARD_OUT=$CLI_OUT CLI_HERE_FORWARD_NVIM=$NVIM_OUT \
  CLI_HERE_FORWARD_ENV=$ENV_OUT \
  HOME="$HOME_FAKE" osascript "$ROOT/driver.scpt" "$ROOT/app.scpt" open "$WORK/a.md" \
  >"$ROOT/out" 2>"$ROOT/err"
t fail/exit 0 "$?"   # the alert branch swallows the error, as designed
t fail/log-has-code 1 "$(grep -c '^3 ' "$LOG")"
t fail/log-has-message 1 "$(grep -c 'cli-here: rules are broken' "$LOG")"
t fail/alert-text 1 "$(grep -c 'ALERT: .*cli-here: rules are broken' "$ROOT/err")"

if [[ $FAILED -ne 0 ]]; then
  echo "forward: FAILED" >&2
  exit 1
fi
echo "forward: all cases match"
