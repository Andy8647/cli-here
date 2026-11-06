#!/bin/bash
# End-to-end quoting test: paths in, the same bytes out of the tool.
#
# The chain under test is the real one, minus Ghostty's window:
#
#   cli-here --(argv)--> osascript --(quoted form, joined)--> bash -c "exec -l"
#     --(argv)--> the tool
#
# A stub `osascript` hands its argv to the real /usr/bin/osascript, whose script
# does exactly what the CLI's embedded AppleScript does: `quoted form of` every
# argument and join with spaces. That string is then fed to a real
# `bash --noprofile --norc -c "exec -l ..."`, which is literally what Ghostty
# runs. A stub `nvim` writes the argv it receives, NUL separated, so a path with
# a newline in it cannot fake a boundary.
#
#   /bin/bash tests/quoting.sh
#   /opt/homebrew/bin/bash tests/quoting.sh
#
# Exit status: 0 every case round-trips, 1 otherwise.

set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
CLI=$REPO/bin/cli-here
BASH_BIN=${BASH_BIN:-/bin/bash}

FAILED=0
CASE=

ROOT=$(cd "$(mktemp -d -t cli-here-quoting)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
WORK=$ROOT/work
STUB=$ROOT/stub
HOME_FAKE=$ROOT/home
EXPECTED=$ROOT/expected.bin
ACTUAL=$ROOT/actual.bin
RECORDED=$ROOT/osascript-argv.bin
mkdir -p "$WORK/dir with space" "$STUB" "$HOME_FAKE"

# The join step, verbatim from the CLI's embedded AppleScript.
cat >"$ROOT/join.applescript" <<'APPLESCRIPT'
on run argv
	set cmd to quoted form of (item 1 of argv)
	repeat with i from 2 to (count of argv)
		set cmd to cmd & " " & quoted form of (item i of argv)
	end repeat
	return cmd
end run
APPLESCRIPT

# Stub nvim: records the argv it was given.
cat >"$STUB/nvim" <<'STUB'
#!/bin/bash
: >"$CLI_HERE_ACTUAL"
for a in "$@"; do printf '%s\0' "$a" >>"$CLI_HERE_ACTUAL"; done
exit 0
STUB

# Stub osascript: records the argv, drains the heredoc, then replays exactly
# what Ghostty would do with the command string the AppleScript built.
cat >"$STUB/osascript" <<'STUB'
#!/bin/bash
: >"$CLI_HERE_RECORDED"
for a in "$@"; do printf '%s\0' "$a" >>"$CLI_HERE_RECORDED"; done
cat >/dev/null

# argv is: - tool cwd mode split bg label toolargs...
shift
tool=$1
shift 9
cmd=$(/usr/bin/osascript "$CLI_HERE_JOIN" "$tool" "$@") || exit 1
exec /bin/bash --noprofile --norc -c "exec -l $cmd"
STUB
chmod +x "$STUB/nvim" "$STUB/osascript"

EXPECT=()

# expect ARGV-TAIL... : the argv the tool should receive after argv[0].
# The tool itself is argv[0], which a script sees as $0 and never in "$@".
expect() {
  EXPECT=("$@")
}

# run_case NAME CLI-ARG... : run the CLI, then compare the tool's argv.
run_case() {
  CASE=$1
  shift
  : >"$EXPECTED"
  local a
  for a in ${EXPECT[@]+"${EXPECT[@]}"}; do printf '%s\0' "$a" >>"$EXPECTED"; done
  : >"$ACTUAL"

  (
    cd "$WORK" || exit 99
    PATH="$STUB:/usr/bin:/bin" HOME="$HOME_FAKE" \
      CLI_HERE_ACTUAL="$ACTUAL" CLI_HERE_RECORDED="$RECORDED" \
      CLI_HERE_JOIN="$ROOT/join.applescript" \
      "$BASH_BIN" "$CLI" "$@" >"$ROOT/out" 2>"$ROOT/err"
  )
  local code=$?
  if [[ $code -ne 0 ]]; then
    echo "FAIL [$CASE] exit $code: $(cat "$ROOT/err")" >&2
    FAILED=1
    return
  fi
  if ! cmp -s "$EXPECTED" "$ACTUAL"; then
    echo "FAIL [$CASE] argv differs" >&2
    echo "  expected: $(tr '\0' '|' <"$EXPECTED")" >&2
    echo "  actual:   $(tr '\0' '|' <"$ACTUAL")" >&2
    echo "  osascript saw: $(tr '\0' '|' <"$RECORDED")" >&2
    FAILED=1
    return
  fi
  echo "ok   [$CASE]"
}

touchf() { : >"$1"; }
touchf "$WORK/sp ace.md"
touchf "$WORK/qu'ote.md"
touchf "$WORK/dol\$lar.md"
touchf "$WORK/back\`tick.md"
touchf "$WORK/中文 é.md"
touchf "$WORK/a&b.md"
touchf "$WORK/new"$'\n'"line.md"
touchf "$WORK/{line}.md"
touchf "$WORK/co:lon.log"
touchf "$WORK/dir with space/x.md"

expect -- "$WORK/sp ace.md"
run_case plain-space "$WORK/sp ace.md"

expect -- "$WORK/qu'ote.md"
run_case single-quote "$WORK/qu'ote.md"

expect -- "$WORK/dol\$lar.md" "$WORK/back\`tick.md"
run_case dollar-backtick "$WORK/dol\$lar.md" "$WORK/back\`tick.md"

expect -- "$WORK/中文 é.md"
run_case cjk "$WORK/中文 é.md"

expect -- "$WORK/a&b.md"
run_case amp "$WORK/a&b.md"

expect -- "$WORK/new"$'\n'"line.md"
run_case newline "$WORK/new"$'\n'"line.md"

# A path containing the text of a placeholder must survive untouched: the
# substitution happens after tokenizing and its output is never re-scanned.
expect -- "$WORK/{line}.md"
run_case literal-placeholder "$WORK/{line}.md"

expect -- "$WORK/co:lon.log"
run_case colon-name "$WORK/co:lon.log"

expect -- "$WORK/dir with space"
run_case dir-with-space "$WORK/dir with space"

expect -- "$WORK/sp ace.md" "$WORK/中文 é.md"
run_case two-files "$WORK/sp ace.md" "$WORK/中文 é.md"

# The :LINE:COL suffix feeds the template, so this also covers `+{line}` plus
# the quoted cursor command coming out with the right spacing.
expect +7 '+call cursor(7,3)' -- "$WORK/sp ace.md"
run_case jump "$WORK/sp ace.md:7:3"

expect --
run_case no-files

if [[ $FAILED -ne 0 ]]; then
  echo "quoting: FAILED ($BASH_BIN)" >&2
  exit 1
fi
echo "quoting: all cases round-trip ($BASH_BIN)"
