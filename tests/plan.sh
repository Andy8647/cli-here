#!/bin/bash
# Plan-level tests: config parsing, rule matching, and the plan a run produces.
# Everything goes through --dry-run, so nothing is opened.
#
#   /bin/bash tests/plan.sh
#   /opt/homebrew/bin/bash tests/plan.sh
#
# Exit status: 0 all cases match, 1 otherwise.

set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
CLI=$REPO/bin/cli-here

FAILED=0
NAME=

ROOT=$(cd "$(mktemp -d -t cli-here-plan)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
WORK=$ROOT/work
HOME_FAKE=$ROOT/home
STUB=$ROOT/stub
CFG=$ROOT/config
OUT=$ROOT/out
ERR=$ROOT/err

mkdir -p "$WORK/db/migrations" "$WORK/dir" "$WORK/Foo.app" \
  "$HOME_FAKE/vault" "$HOME_FAKE/Applications" "$STUB"
touchf() { : >"$1"; }
touchf "$WORK/a.md"
touchf "$WORK/A.MD"
touchf "$WORK/a.ts"
touchf "$WORK/foo.d.ts"
touchf "$WORK/Makefile"
touchf "$WORK/.gitignore"
touchf "$WORK/trail."
touchf "$WORK/db/migrations/001.sql"
touchf "$WORK/db/other.sql"
touchf "$WORK/x.bin"
touchf "$HOME_FAKE/vault/note.md"
touchf "$HOME_FAKE/vault/data.bin"

# Only the presence and the path matter; these are never executed.
for tool in nvim yazi hx; do printf '#!/bin/bash\nexit 0\n' >"$STUB/$tool"; done
chmod +x "$STUB"/*

# run ARGS... : runs the CLI, filling CODE / OUT / ERR
run() {
  : >"$OUT"
  : >"$ERR"
  (
    cd "$WORK" || exit 99
    PATH="$STUB:/usr/bin:/bin" HOME="$HOME_FAKE" CLI_HERE_CONFIG="$CFG" \
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

# plan : the dry-run output as one line, for compact expectations
plan() {
  local out="" line
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    [[ -n $out ]] && out+=" | "
    out+=$line
  done <"$OUT"
  printf '%s' "$out" | norm
}

t() { # t NAME EXPECTED ACTUAL
  if [[ $2 == "$3" ]]; then
    echo "ok   [$1]"
  else
    echo "FAIL [$1]" >&2
    echo "  expected: $2" >&2
    echo "  actual:   $3" >&2
    FAILED=1
  fi
}

# expect_plan NAME ARGS... : run and compare; $PLAN holds the expectation
PLAN=
expect_plan() {
  NAME=$1
  shift
  run --dry-run "$@"
  t "$NAME/exit" 0 "$CODE"
  t "$NAME/plan" "$PLAN" "$(plan)"
}

# expect_config_error NAME LINE MESSAGE CONFIG-TEXT
expect_config_error() {
  NAME=$1
  printf '%s\n' "$4" >"$CFG"
  run --dry-run a.md
  t "$NAME/exit" 2 "$CODE"
  t "$NAME/message" "cli-here: <C>:$2: $3" "$(norm <"$ERR")"
  t "$NAME/no-plan" "" "$(plan)"
}

# --- the matcher matrix ---------------------------------------------------
cat >"$CFG" <<'CONFIG'
# order matters: first match wins
glob:**/migrations/*.sql    => nvim -R +{line} -- {files}
ext:swift,TS                => nvim +{line} -- {files}
noext                       => nvim +{line} -- {files}
dir                         => yazi {files}
ext:sql                     => nvim -- {files}
ext:md, txt                 => hx {loc}
glob:~/vault/**             => nvim -c Vault {files}
*                           => nvim -- {files}
CONFIG

PLAN="surface mode=tab bg=0 cwd=<W> label=a.md rule=config:7 | <S>/hx | <W>/a.md"
expect_plan ext-md a.md

PLAN="surface mode=tab bg=0 cwd=<W> label=A.MD rule=config:7 | <S>/hx | <W>/A.MD"
expect_plan ext-case-insensitive A.MD

PLAN="surface mode=tab bg=0 cwd=<W> label=a.ts rule=config:3 | <S>/nvim | -- | <W>/a.ts"
expect_plan ext-listed-lowercase a.ts

PLAN="surface mode=tab bg=0 cwd=<W> label=foo.d.ts rule=config:3 | <S>/nvim | -- | <W>/foo.d.ts"
expect_plan ext-last-segment-only foo.d.ts

PLAN="surface mode=tab bg=0 cwd=<W> label=Makefile rule=config:4 | <S>/nvim | -- | <W>/Makefile"
expect_plan noext-Makefile Makefile

PLAN="surface mode=tab bg=0 cwd=<W> label=.gitignore rule=config:4 | <S>/nvim | -- | <W>/.gitignore"
expect_plan noext-dotfile .gitignore

PLAN="surface mode=tab bg=0 cwd=<W> label=trail. rule=config:4 | <S>/nvim | -- | <W>/trail."
expect_plan noext-trailing-dot 'trail.'

PLAN="surface mode=tab bg=0 cwd=<W> label=dir rule=config:5 | <S>/yazi | <W>/dir"
expect_plan dir dir

PLAN="surface mode=tab bg=0 cwd=<W> label=Foo.app rule=config:5 | <S>/yazi | <W>/Foo.app"
expect_plan dir-that-looks-like-an-app Foo.app

# The glob rule sits above ext:sql on purpose.
PLAN="surface mode=tab bg=0 cwd=<W> label=001.sql rule=config:2 | <S>/nvim | -R | -- | <W>/db/migrations/001.sql"
expect_plan glob-beats-later-ext db/migrations/001.sql

PLAN="surface mode=tab bg=0 cwd=<W> label=other.sql rule=config:6 | <S>/nvim | -- | <W>/db/other.sql"
expect_plan ext-sql db/other.sql

# ~/ expands against HOME, and ext:md above it still wins for a .md in there.
PLAN="surface mode=tab bg=0 cwd=<W> label=data.bin rule=config:8 | <S>/nvim | -c | Vault | <H>/vault/data.bin"
expect_plan glob-home "$HOME_FAKE/vault/data.bin"

PLAN="surface mode=tab bg=0 cwd=<W> label=note.md rule=config:7 | <S>/hx | <H>/vault/note.md"
expect_plan home-file-still-hits-earlier-ext "$HOME_FAKE/vault/note.md"

PLAN="surface mode=tab bg=0 cwd=<W> label=x.bin rule=config:9 | <S>/nvim | -- | <W>/x.bin"
expect_plan catch-all x.bin

# With a rule table and no arguments, the target is the working directory.
PLAN="surface mode=tab bg=0 cwd=<W> label=work rule=config:5 | <S>/yazi | <W>"
expect_plan no-args-targets-cwd

# --- :LINE / :COL feed the template --------------------------------------
PLAN="surface mode=tab bg=0 cwd=<W> label=a.ts rule=config:3 | <S>/nvim | +42 | -- | <W>/a.ts"
expect_plan line-feeds-template a.ts:42

PLAN="surface mode=tab bg=0 cwd=<W> label=a.md rule=config:7 | <S>/hx | <W>/a.md:42:7"
expect_plan hx-loc a.md:42:7

# --- nvim-here never reads the config -----------------------------------
CFG_SAVED=$CFG
CFG=$ROOT/broken-config
printf 'this line has no arrow\next:md => nvim {foo}\n' >"$CFG"
: >"$OUT"
(
  cd "$WORK" || exit 99
  PATH="$STUB:/usr/bin:/bin" HOME="$HOME_FAKE" CLI_HERE_CONFIG="$CFG" \
    "${BASH_BIN:-/bin/bash}" "$REPO/bin/nvim-here" --dry-run a.md >"$OUT" 2>"$ERR"
)
t nvim-here-ignores-config/exit 0 "$?"
t nvim-here-ignores-config/plan \
  "surface mode=tab bg=0 cwd=<W> label=a.md rule=builtin | <S>/nvim | -- | <W>/a.md" \
  "$(plan)"

# --- no config at all: cli-here equals nvim-here -------------------------
CFG=$ROOT/does-not-exist
PLAN="surface mode=tab bg=0 cwd=<W> label=a.md rule=builtin | <S>/nvim | -- | <W>/a.md"
expect_plan no-config-means-builtin a.md

PLAN="surface mode=tab bg=0 cwd=<W> label=work rule=builtin | <S>/nvim | --"
expect_plan no-config-no-args

CFG=$CFG_SAVED

# --- config errors reject the whole file ---------------------------------
expect_config_error no-arrow 1 \
  "expected ' => ' between the matcher and the action" \
  'ext:md'
expect_config_error unknown-matcher 1 \
  "unknown matcher: exts:md (expected dir, noext, ext:..., glob:..., or *)" \
  'exts:md => nvim -- {files}'
expect_config_error unknown-action 1 \
  'unknown action: @explode' \
  'ext:md => @explode nvim'
expect_config_error bare-open 1 \
  'bare open would call back into this app; write @open' \
  'ext:md => open {file}'
expect_config_error open-with-args 1 \
  '@open takes no arguments' \
  'ext:md => @open nvim'
expect_config_error files-in-a-word 1 \
  '{files} has to be an argument on its own' \
  'ext:md => nvim x{files}'
expect_config_error file-and-line 1 \
  '{file} cannot share an argument with {line} or {col}; use {loc}' \
  'ext:md => nvim {file}:{line}'
expect_config_error unknown-placeholder 1 \
  'unknown placeholder {foo}' \
  'ext:md => nvim {foo}'
expect_config_error unterminated-quote 1 \
  "unterminated '" \
  "ext:md => nvim 'oops"
expect_config_error empty-ext 1 \
  'ext: needs at least one extension' \
  'ext: => nvim -- {files}'
expect_config_error empty-glob 1 \
  'glob: needs a pattern' \
  'glob: => nvim -- {files}'

# A bad rule anywhere rejects the file, even if an earlier rule would match.
expect_config_error bad-rule-after-good 3 \
  'unknown matcher: nope (expected dir, noext, ext:..., glob:..., or *)' \
  'ext:md => nvim -- {files}

nope => nvim -- {files}'

# --- tolerated syntax ----------------------------------------------------
printf '\n# comment\n   \n  ext:md  =>  nvim -- {files}   \n\next:bin => nvim -- {files}\n' >"$CFG"
PLAN="surface mode=tab bg=0 cwd=<W> label=a.md rule=config:4 | <S>/nvim | -- | <W>/a.md"
expect_plan indented-and-blank-lines a.md

printf 'ext:md, txt => nvim -- {files}\n' >"$CFG"
PLAN="surface mode=tab bg=0 cwd=<W> label=a.md rule=config:1 | <S>/nvim | -- | <W>/a.md"
expect_plan spaces-around-extensions a.md

printf 'ext:md => nvim -- {files}\r\next:bin => nvim -- {files}\r\n' >"$CFG"
PLAN="surface mode=tab bg=0 cwd=<W> label=x.bin rule=config:2 | <S>/nvim | -- | <W>/x.bin"
expect_plan crlf-line-endings x.bin

if [[ $FAILED -ne 0 ]]; then
  echo "plan: FAILED" >&2
  exit 1
fi
echo "plan: all cases match"
