#!/bin/bash
# Unit tests for the template machinery: tokenize, validate_template, and
# expand_template. The CLI is sourced, not executed, so nothing opens.
#
#   /bin/bash tests/template.sh
#   /opt/homebrew/bin/bash tests/template.sh
#
# Exit status: 0 everything passes, 1 otherwise.

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

# shellcheck source=../bin/cli-here shell=bash
# shellcheck disable=SC1091
source "$REPO/bin/cli-here"
# The CLI runs under -euo; -e would abort this script on the first assertion.
set +e

FAILED=0
t() { # t NAME EXPECTED ACTUAL
  if [[ $2 == "$3" ]]; then
    echo "ok   [$1]"
  else
    echo "FAIL [$1] expected {$2} got {$3}" >&2
    FAILED=1
  fi
}

# join WORDS... -> them as a |-separated string
join() {
  local a out=""
  for a in "$@"; do out+="$a|"; done
  printf '%s' "$out"
}

# --- tokenize -------------------------------------------------------------

tokenize "nvim a.md"
t simple-count 2 "${#TOKS[@]}"
t simple-args "nvim|a.md|" "$(join "${TOKS[@]}")"

tokenize "nvim +{line} '+call cursor({line},{col})' -- {files}"
t quoted-count 5 "${#TOKS[@]}"
t quoted-grouping "+call cursor({line},{col})" "${TOKS[2]}"

tokenize 'a"b c"d'
t adjacent-quotes "ab cd|" "$(join "${TOKS[@]}")"

tokenize "x' y 'z"
t quote-midword "x y z|" "$(join "${TOKS[@]}")"

tokenize "''"
t empty-token "1:" "${#TOKS[@]}:${TOKS[0]}"

tokenize 'a\ b'
t backslash-is-literal "a\\|b|" "$(join "${TOKS[@]}")"

tokenize "it's"
t unterminated-status 1 "$?"
t unterminated-message "unterminated '" "$TOKENIZE_ERROR"

tokenize 'say "hi"'
t double-quotes "say|hi|" "$(join "${TOKS[@]}")"

tokenize "   "
t blank-only 0 "${#TOKS[@]}"

# --- validate_template ----------------------------------------------------
#
# Not $(...): the point is to read VALIDATE_ERROR, which a subshell would keep
# to itself.
V_STATUS=0
V_ERROR=""
check_validate() {
  tokenize "$1"
  validate_template
  V_STATUS=$?
  V_ERROR=$VALIDATE_ERROR
}

check_validate "$BUILTIN_ACTION"
t ok-builtin 0 "$V_STATUS"
check_validate 'nvim {file}'
t ok-per-file 0 "$V_STATUS"
check_validate 'code -g {loc}'
t ok-loc 0 "$V_STATUS"
check_validate 'nvim {files}'
t ok-files-alone 0 "$V_STATUS"
check_validate 'nvim {}'
t ok-empty-braces 0 "$V_STATUS"
check_validate 'nvim {a=1}'
t ok-braces-with-equals 0 "$V_STATUS"
check_validate 'nvim {line'
t ok-unbalanced-brace 0 "$V_STATUS"
check_validate 'nvim {Line}'
t ok-capitalised 0 "$V_STATUS"

check_validate 'nvim {files}.bak'
t bad-files-in-word 1 "$V_STATUS"
t bad-files-message "{files} has to be an argument on its own" "$V_ERROR"
check_validate 'nvim {file}:{line}'
t bad-file-plus-line 1 "$V_STATUS"
t bad-file-plus-line-message \
  "{file} cannot share an argument with {line} or {col}; use {loc}" "$V_ERROR"
check_validate 'nvim {foo}'
t bad-unknown-placeholder 1 "$V_STATUS"
t bad-unknown-message "unknown placeholder {foo}" "$V_ERROR"

# --- expand_template ------------------------------------------------------

# expand TEMPLATE LINE COL DIR PATH... -> expanded argv as a |-separated string
expand() {
  local template=$1 line=$2 col=$3 dir=$4
  shift 4
  tokenize "$template"
  expand_template "$line" "$col" "$dir" "$@"
  join ${EXPANDED[@]+"${EXPANDED[@]}"}
}

t jump-both "nvim|+42|+call cursor(42,7)|--|/f/a.md|" \
  "$(expand "$BUILTIN_ACTION" 42 7 /f /f/a.md)"
t jump-line-only "nvim|+42|--|/f/a.md|" \
  "$(expand "$BUILTIN_ACTION" 42 "" /f /f/a.md)"
t jump-none "nvim|--|/f/a.md|" \
  "$(expand "$BUILTIN_ACTION" "" "" /f /f/a.md)"
t jump-no-files "nvim|--|" \
  "$(expand "$BUILTIN_ACTION" "" "" /f)"

t loc-both "nvim|/f/a.md:42:7|" "$(expand 'nvim {loc}' 42 7 /f /f/a.md)"
t loc-line "nvim|/f/a.md:42|" "$(expand 'nvim {loc}' 42 "" /f /f/a.md)"
t loc-bare "nvim|/f/a.md|" "$(expand 'nvim {loc}' "" "" /f /f/a.md)"

t file-first "nvim|/f/a.md|" "$(expand 'nvim {file}' "" "" /f /f/a.md /f/b.md)"

t dir-and-files "yazi|/f/x|/f/a.md|/f/b.md|" \
  "$(expand 'yazi {dir} {files}' "" "" /f/x /f/a.md /f/b.md)"

# A token that needs a value the entry lacks disappears whole, not partially.
t mixed-token-dropped "nvim|" "$(expand 'nvim {line}x' "" "" /f /f/a.md)"

t literal-braces-kept "nvim|{a=1}|+9|" "$(expand 'nvim {a=1} +{line}' 9 "" /f)"

if [[ $FAILED -ne 0 ]]; then
  echo "template: FAILED" >&2
  exit 1
fi
echo "template: all assertions pass"
