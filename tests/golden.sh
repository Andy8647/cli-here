#!/bin/bash
# Behaviour snapshot of the nvim-here entry point.
#
# Nothing in the product is touched. A stub `osascript` earlier in PATH records
# the argv the CLI would have handed to Ghostty, a stub `nvim` makes tool lookup
# deterministic, and HOME is a sandbox. stdout, stderr, exit status and that argv
# are written out as one text block per case, so the whole comparison is `diff`.
#
#   tests/golden.sh record          # both bash versions -> tests/golden/
#   tests/golden.sh check           # diff the current tree against those files
#   tests/golden.sh record --bash /bin/bash --entry bin/cli-here
#
# Exit status: 0 everything matches, 1 at least one case differs.
#
# Note on ${v//pat/repl}: bash 5.x with patsub_replacement expands `&` in the
# replacement, 3.2 does not. Every replacement below is a fixed placeholder with
# no `&`, so the two versions produce byte-identical output.

set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

MODE=${1:-}
case $MODE in
  record|check) shift ;;
  *) echo "usage: tests/golden.sh record|check [--bash PATH] [--entry PATH]" >&2; exit 2 ;;
esac

ENTRY=$REPO/bin/nvim-here
BASH_LIST=
while [[ $# -gt 0 ]]; do
  case $1 in
    --bash) BASH_LIST="$BASH_LIST $2"; shift 2 ;;
    --entry) ENTRY=$2; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n $BASH_LIST ]] || BASH_LIST=" /bin/bash /opt/homebrew/bin/bash"

# Cases run from a sandbox cwd, so a relative --entry would not resolve there.
[[ $ENTRY == /* ]] || ENTRY=$PWD/$ENTRY
if [[ ! -f $ENTRY ]]; then
  echo "no such entry point: $ENTRY" >&2
  exit 2
fi
ENTRY_NAME=$(basename "$ENTRY")

# Sanitise one string: sandbox paths become placeholders. Order matters, the
# nested directories have to go before their parent.
norm() {
  local s=$1
  s=${s//"$HOME_FAKE"/<HOME>}
  s=${s//"$STUB"/<STUB>}
  s=${s//"$ROOT"/<ROOT>}
  printf '%s' "$s"
}

# Same, plus the escapes that keep one line per value for the odd file name.
esc() {
  local s
  s=$(norm "$1")
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

block() {
  local name=$1 code=$2 out=$3 err=$4 argv=$5 stdin_flag=$6

  printf '### %s\n' "$name"
  printf 'cwd: %s\n' "$(esc "$RUN_CWD_ACTUAL")"
  printf 'entry: %s\n' "$ENTRY_NAME"
  printf 'exit: %s\n' "$code"

  if [[ -n $out ]]; then
    printf 'out:\n'
    while IFS= read -r line; do printf '  | %s\n' "$(esc "$line")"; done <<<"$out"
  else
    printf 'out: (empty)\n'
  fi
  if [[ -n $err ]]; then
    printf 'err:\n'
    while IFS= read -r line; do printf '  | %s\n' "$(esc "$line")"; done <<<"$err"
  else
    printf 'err: (empty)\n'
  fi

  printf 'stdin: %s\n' "$stdin_flag"
  local i=0 line
  while IFS= read -r line; do
    if [[ $i -eq 0 ]]; then
      printf 'argc: %s\n' "$line"
    else
      printf 'argv[%d] = %s\n' "$((i - 1))" "$(esc "$line")"
    fi
    i=$((i + 1))
  done <"$argv"
}

# run_case NAME [ARGS...]
#
# Defaults, overridable by setting the RUN_* variable on the line before:
#   RUN_CWD     directory to run in            (default $WORK)
#   RUN_PATH    PATH for the child             (default stub + system dirs)
#   RUN_DIRECT  1 = exec the entry itself, 0 = `bash <entry>`
run_case() {
  local name=$1
  shift

  local path=${RUN_PATH:-$STUB:/usr/bin:/bin:/usr/sbin:/sbin}
  local cwd=${RUN_CWD:-$WORK}
  local direct=${RUN_DIRECT:-0}
  RUN_CWD_ACTUAL=$cwd

  : >"$OUT/argv"
  : >"$OUT/stdin"
  : >"$OUT/stdout"
  : >"$OUT/stderr"

  (
    cd "$cwd" || exit 99
    # EDITOR is pinned: it is part of what a surface is told, and inheriting it
    # from whoever runs the suite would put their shell in the snapshot.
    if [[ $direct -eq 1 ]]; then
      PATH="$path" HOME="$HOME_FAKE" EDITOR=nvim \
        CLI_HERE_GOLDEN_ARGV="$OUT/argv" CLI_HERE_GOLDEN_STDIN="$OUT/stdin" \
        "$ENTRY" "$@" >"$OUT/stdout" 2>"$OUT/stderr"
    else
      PATH="$path" HOME="$HOME_FAKE" EDITOR=nvim \
        CLI_HERE_GOLDEN_ARGV="$OUT/argv" CLI_HERE_GOLDEN_STDIN="$OUT/stdin" \
        "$BASH_BIN" "$ENTRY" "$@" >"$OUT/stdout" 2>"$OUT/stderr"
    fi
  )
  local code=$?

  local stdin_flag=no
  [[ -s $OUT/stdin ]] && stdin_flag=yes

  local text
  text=$(block "$name" "$code" "$(cat "$OUT/stdout")" "$(cat "$OUT/stderr")" \
    "$OUT/argv" "$stdin_flag")

  # A path that survived norm() would make the file machine-specific.
  if [[ $text == *'/var/folders/'* || $text == *"$HOME"* ]]; then
    echo "warn: $name leaked an un-normalised path" >&2
  fi
  printf '%s\n' "$text"
}

run_suite() {
  BASH_BIN=$1

  ROOT=$(cd "$(mktemp -d -t cli-here-golden)" && pwd -P)
  WORK=$ROOT/work
  HOME_FAKE=$ROOT/home
  STUB=$ROOT/stub
  OUT=$ROOT/out
  mkdir -p "$WORK/src" "$WORK/dir" "$WORK/sub/inner" "$HOME_FAKE" "$STUB" "$OUT"

  # Stub osascript: records the argv, drains the heredoc, succeeds.
  # Newlines and tabs are escaped so one argument stays one line; a name that
  # really contains a backslash-n is therefore indistinguishable from a newline.
  cat >"$STUB/osascript" <<'STUB'
#!/bin/bash
f="$CLI_HERE_GOLDEN_ARGV"
{
  printf '%s\n' "$#"
  for a in "$@"; do
    a=${a//$'\n'/\\n}
    a=${a//$'\t'/\\t}
    printf '%s\n' "$a"
  done
} >>"$f"
cat >"$CLI_HERE_GOLDEN_STDIN"
exit 0
STUB
  # Stub nvim: only ever resolved by `command -v`, never executed.
  printf '#!/bin/bash\nexit 0\n' >"$STUB/nvim"
  chmod +x "$STUB/osascript" "$STUB/nvim"
  PATH_NO_NVIM=/usr/bin:/bin

  touchf() { : >"$WORK/$1"; }
  touchf a.md
  touchf b.py
  touchf Makefile
  touchf .gitignore
  touchf 'trail.'
  touchf 'test:2024.log'
  touchf 'weird name.txt'
  touchf '中文 é.md'
  touchf "single'quote.md"
  # shellcheck disable=SC2016  # the dollar sign is part of the file name
  touchf 'with$dollar.md'
  touchf '{line}.md'
  touchf 'a&b.md'
  touchf 'back`tick.md'
  touchf $'new\nline.md'
  touchf 'dash.md'
  touchf '-dash.md'
  touchf src/foo.ts
  touchf dir/keep.txt
  : >"$HOME_FAKE/x.md"
  ln -s sub "$WORK/linkdir"

  printf '# behaviour snapshot through %s\n# entry: %s\n\n' \
    "$("$BASH_BIN" --version | head -1)" "$ENTRY_NAME"

  # --- argument parsing -----------------------------------------------------
  run_case no-args
  run_case help -h
  run_case help-long --help
  run_case ddash-only --
  run_case unknown-opt -x
  run_case unknown-opt-after-file a.md -z
  run_case ddash-dashfile -- -dash.md
  run_case ddash-then-looking-like-flag -- -b a.md

  # --- paths ---------------------------------------------------------------
  run_case one-file a.md
  run_case one-file-abs "$WORK/a.md"
  # shellcheck disable=SC2088  # literal prefix: nvim-here expands it, the shell must not
  run_case one-file-tilde '~/x.md'
  run_case one-file-dotdot ../work/a.md
  run_case dir-arg dir
  run_case dir-arg-slash dir/
  run_case noext Makefile
  run_case dotfile .gitignore
  run_case trailing-dot 'trail.'
  run_case nonexistent nope.ts
  run_case nonexistent-with-line nope.ts:9
  run_case two-files a.md b.py
  run_case many a.md b.py src/foo.ts dir 'test:2024.log' nope.ts

  # --- :LINE / :COL --------------------------------------------------------
  run_case line src/foo.ts:42
  run_case line-col src/foo.ts:42:7
  run_case line-zero src/foo.ts:0
  run_case line-leading-zero src/foo.ts:007
  run_case colon-name 'test:2024.log'
  run_case colon-name-with-line 'test:2024.log:12'
  run_case two-files-line-first a.md:3 b.py
  run_case two-files-line-second a.md b.py:7

  # --- quoting hazards -----------------------------------------------------
  run_case spaces 'weird name.txt'
  run_case cjk '中文 é.md'
  run_case singlequote "single'quote.md"
  # shellcheck disable=SC2016  # the dollar sign is part of the file name
  run_case dollar 'with$dollar.md'
  run_case brace '{line}.md'
  run_case amp 'a&b.md'
  run_case backtick 'back`tick.md'
  run_case newline $'new\nline.md'

  # --- placement flags -----------------------------------------------------
  run_case bg -b a.md
  run_case bg-long --background a.md
  run_case window -w a.md
  run_case window-long --new-window a.md
  run_case window-no-file -w
  run_case split -s a.md
  run_case split-long --split a.md
  run_case split-down --split=down a.md
  run_case split-up --split=up a.md
  run_case split-left --split=left a.md
  run_case split-right --split=right a.md
  run_case split-bogus --split=diagonal a.md
  run_case bg-split -b --split=down a.md
  run_case conflict-w-s -w -s a.md
  run_case conflict-s-w -s -w a.md
  run_case conflict-w-split-up -w --split=up a.md

  # --- -C ------------------------------------------------------------------
  run_case dir-flag -C sub a.md
  run_case dir-flag-abs -C "$WORK/dir" a.md
  run_case dir-flag-dotdot -C sub/.. a.md
  run_case dir-flag-symlink -C linkdir a.md
  run_case dir-flag-twice -C dir -C sub a.md
  run_case dir-flag-missing-value -C
  run_case dir-flag-nonexistent -C nope a.md
  run_case dir-flag-is-file -C a.md

  # --- environment ---------------------------------------------------------
  RUN_PATH=$PATH_NO_NVIM
  run_case nvim-missing a.md
  RUN_PATH=

  RUN_DIRECT=1
  run_case direct-invocation a.md
  RUN_DIRECT=

  rm -rf "$ROOT"
}

tag_for() {
  "$1" --version | head -1 | sed -e 's/^GNU bash, version //' -e 's/ .*//' -e 's/\([0-9]*\.[0-9]*\).*/\1/'
}

mkdir -p "$HERE/golden"
# GOLDEN_DIR lets a one-off run land somewhere else, e.g. recording the same
# cases through bin/cli-here to diff the two entry points against each other.
GOLDEN_DIR=${GOLDEN_DIR:-$HERE/golden}
mkdir -p "$GOLDEN_DIR"
status=0
for bash_bin in $BASH_LIST; do
  if [[ ! -x $bash_bin ]]; then
    echo "skip (missing): $bash_bin" >&2
    continue
  fi
  tag="bash-$(tag_for "$bash_bin")"
  file="$GOLDEN_DIR/$tag.txt"

  case $MODE in
    record)
      run_suite "$bash_bin" >"$file.tmp"
      mv "$file.tmp" "$file"
      echo "recorded: ${file#"$REPO"/} ($(grep -c '^### ' "$file") cases)" >&2
      ;;
    check)
      run_suite "$bash_bin" >"$file.actual"
      if diff -u "$file" "$file.actual" >"$file.diff"; then
        echo "pass: $tag" >&2
        rm -f "$file.diff"
      else
        echo "FAIL: $tag" >&2
        cat "$file.diff" >&2
        status=1
      fi
      rm -f "$file.actual"
      ;;
  esac
done

# The two bash versions must agree with each other word for word.
if [[ $MODE == record ]]; then
  first=
  for bash_bin in $BASH_LIST; do
    file="$GOLDEN_DIR/bash-$(tag_for "$bash_bin").txt"
    [[ -f $file ]] || continue
    if [[ -z $first ]]; then
      first=$file
    elif ! diff -u <(tail -n +2 "$first") <(tail -n +2 "$file"); then
      echo "FAIL: bash versions disagree" >&2
      status=1
    fi
  done
fi

exit $status
