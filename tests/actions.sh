#!/bin/bash
# Grouping, @run and @open: what the plan says and what actually runs.
#
# Every external program here is a stub: `open` records its argv, `osascript`
# records that it was called at all (an @run or @open action must never reach
# Ghostty), and the dump tool records the argv and working directory it got.
#
#   /bin/bash tests/actions.sh
#   /opt/homebrew/bin/bash tests/actions.sh
#
# Exit status: 0 all cases match, 1 otherwise.

set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
CLI=$REPO/bin/cli-here

FAILED=0
NAME=

ROOT=$(cd "$(mktemp -d -t cli-here-actions)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
WORK=$ROOT/work
HOME_FAKE=$ROOT/home
STUB=$ROOT/stub
CFG=$ROOT/config
OUT=$ROOT/out
ERR=$ROOT/err
DUMP_OUT=$ROOT/dump-out
OPEN_OUT=$ROOT/open-out
OSA_MARK=$ROOT/osascript-called
mkdir -p "$WORK" "$HOME_FAKE" "$STUB" "$HOME_FAKE/Applications"

touchf() { : >"$1"; }
touchf "$WORK/a.md"
touchf "$WORK/b.md"
touchf "$WORK/x.bin"
touchf "$WORK/y.txt"
touchf "$WORK/z.txt"

# Stub osascript: proves whether anything tried to reach Ghostty.
cat >"$STUB/osascript" <<'STUB'
#!/bin/bash
{
  printf 'n %s\n' "$#"
  for a in "$@"; do printf 'arg %s\n' "$a"; done
} >>"$CLI_HERE_OSA_MARK"
exit 0
STUB

# Stub open: records the argv it would have handed to LaunchServices.
cat >"$STUB/open" <<'STUB'
#!/bin/bash
: >"$CLI_HERE_OPEN_OUT"
for a in "$@"; do printf '%s\0' "$a" >>"$CLI_HERE_OPEN_OUT"; done
exit 0
STUB

# Stub tool for @run: records argv and cwd.
cat >"$STUB/dump" <<'STUB'
#!/bin/bash
{
  printf 'cwd %s\n' "$PWD"
  for a in "$@"; do printf 'arg %s\n' "$a"; done
} >"$CLI_HERE_DUMP_OUT"
exit 0
STUB

for tool in nvim yazi hx; do printf '#!/bin/bash\nexit 0\n' >"$STUB/$tool"; done
chmod +x "$STUB"/*

# run ARGS... : runs the CLI with every stub in place. CLI_HERE_HANDLER is left
# to the caller: @open tests set it, so no case here queries LaunchServices.
run() {
  : >"$OUT"
  : >"$ERR"
  : >"$DUMP_OUT"
  : >"$OPEN_OUT"
  : >"$OSA_MARK"
  (
    cd "$WORK" || exit 99
    PATH="$STUB:/usr/bin:/bin" HOME="$HOME_FAKE" CLI_HERE_CONFIG="$CFG" \
      CLI_HERE_DUMP_OUT="$DUMP_OUT" CLI_HERE_OPEN_OUT="$OPEN_OUT" \
      CLI_HERE_OSA_MARK="$OSA_MARK" \
      "${BASH_BIN:-/bin/bash}" "$CLI" "$@" >"$OUT" 2>"$ERR"
  )
  CODE=$?
}

norm() {
  local s
  s=$(cat)
  s=${s//"$WORK"/<W>}
  s=${s//"$HOME_FAKE"/<H>}
  s=${s//"$STUB"/<S>}
  s=${s//"$CFG"/<C>}
  printf '%s' "$s"
}

# Each action is separated by " || ", each argv word by " | ".
plan() {
  local out="" line
  while IFS= read -r line; do
    if [[ $line == [[:space:]]* ]]; then
      out+=" | "
      out+=${line#"${line%%[![:space:]]*}"}
    else
      [[ -n $out ]] && out+=" || "
      out+=$line
    fi
  done <"$OUT"
  printf '%s' "$out" | norm
}

# nulldump FILE -> its NUL-separated words, | separated
nulldump() {
  local a out=""
  if [[ -s $1 ]]; then
    while IFS= read -r -d '' a; do out+="$a|"; done <"$1"
  fi
  printf '%s' "$out"
}

# lines FILE -> the file's lines, ; separated, so a whole dump fits in one arg
lines() { norm <"$1" | tr '\n' ';'; }

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

expect_plan() { # expect_plan NAME ARGS... ; $PLAN holds the expectation
  NAME=$1
  shift
  run --dry-run "$@"
  t "$NAME/exit" 0 "$CODE"
  t "$NAME/plan" "$PLAN" "$(plan)"
}

# --- grouping -------------------------------------------------------------
cat >"$CFG" <<'CONFIG'
ext:md  => nvim +{line} -- {files}
ext:bin => yazi {files}
ext:txt => hx {loc}
CONFIG

PLAN="surface mode=tab bg=0 cwd=<W> label=a.md rule=config:1 | <S>/nvim | -- | <W>/a.md || surface mode=tab bg=0 cwd=<W> label=x.bin rule=config:2 | <S>/yazi | <W>/x.bin || surface mode=tab bg=0 cwd=<W> label=y.txt rule=config:3 | <S>/hx | <W>/y.txt"
expect_plan three-groups a.md x.bin y.txt

# Same rule, two files: one action. Group order follows the arguments, not the
# order of the rules in the file.
PLAN="surface mode=tab bg=0 cwd=<W> label=b.md +1 rule=config:1 | <S>/nvim | -- | <W>/b.md | <W>/a.md || surface mode=tab bg=0 cwd=<W> label=x.bin rule=config:2 | <S>/yazi | <W>/x.bin"
expect_plan regrouped-by-first-appearance b.md a.md x.bin

# {loc} means one action per file, each with its own line.
PLAN="surface mode=tab bg=0 cwd=<W> label=y.txt rule=config:3 | <S>/hx | <W>/y.txt:2 || surface mode=tab bg=0 cwd=<W> label=z.txt rule=config:3 | <S>/hx | <W>/z.txt:9"
expect_plan per-file-template y.txt:2 z.txt:9

# A line number on a later file of a {files} group is dropped, and said.
run --dry-run a.md:3 b.md:9
t dropped-line/exit 0 "$CODE"
t dropped-line/note \
  "cli-here: note: :9 belongs to <W>/b.md, but nvim applies it to <W>/a.md" \
  "$(norm <"$ERR")"
t dropped-line/first-line-wins \
  "surface mode=tab bg=0 cwd=<W> label=a.md +1 rule=config:1 | <S>/nvim | +3 | -- | <W>/a.md | <W>/b.md" \
  "$(plan)"

# A missing file is a note for a surface rule: the tool can create it.
run --dry-run nope.md
t missing-surface/exit 0 "$CODE"
t missing-surface/note \
  "cli-here: note: <W>/nope.md does not exist, nvim will create it" \
  "$(norm <"$ERR")"

# --- @run -----------------------------------------------------------------
printf 'ext:bin => @run %s/dump -- {files}\n' "$STUB" >"$CFG"

PLAN="run cwd=<W> rule=config:1 | <S>/dump | -- | <W>/x.bin"
expect_plan run-plan x.bin

run x.bin
t run-exec/exit 0 "$CODE"
t run-exec/cwd-and-argv "cwd <W>;arg --;arg <W>/x.bin" "$(lines "$DUMP_OUT")"
t run-exec/no-osascript "" "$(cat "$OSA_MARK")"

# The exit code comes back out, so a rule can be used from a git hook.
printf "ext:bin => @run /bin/sh -c 'exit 7'\n" >"$CFG"
run x.bin
t run-exit-code/exit 7 "$CODE"

# Placement flags make no sense without a terminal: note, then ignore.
printf 'ext:bin => @run %s/dump -- {files}\n' "$STUB" >"$CFG"
run --dry-run -b x.bin
t run-bg-note "cli-here: note: --background is ignored for @run" "$(norm <"$ERR")"
run --dry-run -w x.bin
t run-window-note "cli-here: note: --new-window is ignored for @run" "$(norm <"$ERR")"
run --dry-run --split=down x.bin
t run-split-note "cli-here: note: --split is ignored for @run" "$(norm <"$ERR")"

# @run has nothing useful to do with a path that is not there.
run --dry-run nope.bin
NAME=run-missing
t "$NAME/exit" 1 "$CODE"
t "$NAME/message" "cli-here: <W>/nope.bin does not exist" "$(norm <"$ERR")"

# --- @open ----------------------------------------------------------------
printf 'ext:bin => @open\n' >"$CFG"

export CLI_HERE_HANDLER=com.apple.TextEdit
PLAN="open rule=config:1 | <S>/open | <W>/x.bin"
expect_plan open-other-app x.bin

PLAN="open rule=config:1 | <S>/open | -g | <W>/x.bin"
expect_plan open-background-uses-g -b x.bin

run x.bin
t open-exec/exit 0 "$CODE"
t open-exec/argv "<W>/x.bin|" "$(nulldump "$OPEN_OUT" | norm)"
t open-exec/no-osascript "" "$(cat "$OSA_MARK")"

run -w --dry-run x.bin
t open-window-note "cli-here: note: --new-window is ignored for @open" "$(norm <"$ERR")"

# The handler is this app: opening it would come straight back here.
export CLI_HERE_HANDLER=dev.andy.nvimhere
run --dry-run x.bin
NAME=open-self
t "$NAME/exit" 0 "$CODE"
t "$NAME/note" \
  "cli-here: note: <W>/x.bin is handled by NvimHere itself; opening nvim instead" \
  "$(norm <"$ERR")"
t "$NAME/falls-back-to-nvim" \
  "surface mode=tab bg=0 cwd=<W> label=x.bin rule=config:1 | <S>/nvim | -- | <W>/x.bin" \
  "$(plan)"

# The same, recognised by path rather than by bundle id.
export CLI_HERE_HANDLER="$HOME_FAKE/Applications/NvimHere.app"
run --dry-run x.bin
t open-self-by-path/exit 0 "$CODE"
t open-self-by-path/note-is-present 1 "$(grep -c 'handled by NvimHere' <<<"$(norm <"$ERR")")"

# Nothing claims the file.
export CLI_HERE_HANDLER=""
run --dry-run x.bin
NAME=open-no-handler
t "$NAME/exit" 1 "$CODE"
t "$NAME/message" "cli-here: no app claims <W>/x.bin; add a rule for it" "$(norm <"$ERR")"

export CLI_HERE_HANDLER=com.apple.TextEdit
run --dry-run nope.bin
NAME=open-missing
t "$NAME/exit" 1 "$CODE"
t "$NAME/message" "cli-here: <W>/nope.bin does not exist" "$(norm <"$ERR")"

# --- a mixed plan: every group runs, in order ----------------------------
cat >"$CFG" <<CONFIG
ext:md  => nvim -- {files}
ext:bin => @run $STUB/dump -- {files}
ext:txt => @open
CONFIG

run a.md x.bin y.txt
t mixed/exit 0 "$CODE"
t mixed/run-argv "cwd <W>;arg --;arg <W>/x.bin" "$(lines "$DUMP_OUT")"
t mixed/open-argv "<W>/y.txt|" "$(nulldump "$OPEN_OUT" | norm)"
t mixed/surface-went-through-ghostty 1 "$(grep -c '^arg -$' "$OSA_MARK")"

# --- what a surface is told: argv slots 7, 8, 9 ---------------------------
printf 'ext:md => nvim -- {files}\n' >"$CFG"
export EDITOR=eleven
run --hold a.md
t surface-slots/hold-and-env \
  "n 12;arg -;arg <S>/nvim;arg <W>;arg tab;arg right;arg 0;arg a.md;arg 1;arg PATH=<S>:/usr/bin:/bin;arg EDITOR=eleven;arg --;arg <W>/a.md" \
  "$(lines "$OSA_MARK")"

unset EDITOR
run --hold a.md
t surface-slots/no-editor \
  "n 12;arg -;arg <S>/nvim;arg <W>;arg tab;arg right;arg 0;arg a.md;arg 1;arg PATH=<S>:/usr/bin:/bin;arg ;arg --;arg <W>/a.md" \
  "$(lines "$OSA_MARK")"

run a.md
t surface-slots/no-hold \
  "n 12;arg -;arg <S>/nvim;arg <W>;arg tab;arg right;arg 0;arg a.md;arg 0;arg PATH=<S>:/usr/bin:/bin;arg ;arg --;arg <W>/a.md" \
  "$(lines "$OSA_MARK")"

if [[ $FAILED -ne 0 ]]; then
  echo "actions: FAILED" >&2
  exit 1
fi
echo "actions: all cases match"
