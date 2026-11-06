#!/usr/bin/env bash
# Build and install NvimHere.app, then point file associations at it.
#
#   ./install.sh                 # build + register + apply associations
#   ./install.sh --no-duti       # build + register only, no association changes
#   ./install.sh --claim-folders # also make the app the handler for folders
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="NvimHere"
BUNDLE_ID="dev.andy.nvimhere"
APP="$HOME/Applications/$APP_NAME.app"
TEMPLATE="$HERE/src/$APP_NAME.applescript"

APPLY_DUTI=1
FORCE_BUILD=0
CLAIM_FOLDERS=0
for arg in "$@"; do
  case "$arg" in
    --no-duti) APPLY_DUTI=0 ;;
    --force) FORCE_BUILD=1 ;;
    --no-build) FORCE_BUILD=0 ;;
    --claim-folders) CLAIM_FOLDERS=1 ;;
    --no-claim-folders) CLAIM_FOLDERS=2 ;;
  esac
done

# Extensions we claim. Add or remove freely; rerun with --force to apply.
# Declaring these matters: extensions that no app declares resolve to throwaway
# `dyn.*` types, and LaunchServices refuses to store a user default for those.
EXTS=(
  md markdown mdx txt text log rst adoc
  ts tsx mts cts js jsx mjs cjs vue svelte astro
  json jsonc json5 yaml yml toml ini conf cfg env properties gradle
  css scss sass less styl html htm
  lua py pyi go rs rb java kt kts scala clj cljs dart swift
  c h cc cpp cxx hpp hxx cs php sh bash zsh fish ps1 bat
  sql graphql gql tex bib biblatex typ
  nix zig nim ex exs erl hs ml fs jl r pl pm el vim m mm
  dockerfile gitignore gitattributes editorconfig lock tf tfvars
)

# Broad UTIs cover most of the list. Several of these are added purely to
# override explicit per-type preferences left behind by VS Code.
UTIS=(
  public.plain-text
  public.source-code
  public.text
  public.json
  net.daringfireball.markdown
  public.yaml
  public.xml
  public.shell-script
  public.bash-script
  public.zsh-script
  public.perl-script
  public.ruby-script
  public.python-script
  public.c-source
  public.c-plus-plus-source
  public.objective-c-source
  public.objective-c-plus-plus-source
  public.swift-source
  public.property-list
  public.rtf
)

# public.html is deliberately absent: macOS maps the HTML handler onto the system
# default browser (com.apple.default-app.web-browser plus the http/https schemes).
# Claiming it makes every web link open in this shim instead of a browser.
if [[ " ${UTIS[*]} " == *" public.html "* ]]; then
  echo "error: never claim public.html, it hijacks the default browser" >&2
  exit 1
fi

# nvim is no longer required to install: the app only forwards to cli-here, and
# the rule table decides what runs. Without nvim the default rule will fail when
# it fires, which is a runtime problem with a clear message.
if ! command -v nvim >/dev/null; then
  echo "warn: nvim is not in PATH; the built-in rule will not be able to run" >&2
fi

# Never rebuild over an existing install unless asked: deleting the bundle makes
# LaunchServices drop every association that points at it, which means the user
# has to re-approve each default-app dialog from scratch. Only the compiled
# script is swapped, which keeps the bundle (and every approval) intact.
#
# sed cannot inject these values safely: | is the delimiter, & expands to the
# match, and a " would end the AppleScript string literal.
check_value() {
  local name=$1 value=$2 bad
  for bad in '|' '&' '"'; do
    case $value in
      *"$bad"*)
        echo "error: $name contains $bad, which the installer cannot substitute safely" >&2
        exit 1 ;;
    esac
  done
}

CLI_HERE_BIN="$HERE/bin/cli-here"
NVIM_HERE_BIN="$HERE/bin/nvim-here"
INSTALL_PATH=${PATH:-/usr/bin:/bin}
INSTALL_EDITOR=${EDITOR:-}
check_value PATH "$INSTALL_PATH"
check_value EDITOR "$INSTALL_EDITOR"
check_value "cli-here" "$CLI_HERE_BIN"
check_value "nvim-here" "$NVIM_HERE_BIN"

build_app() {
  local out="$1" tmp_script
  tmp_script="$(mktemp -t nvimhere).applescript"
  sed -e "s|__CLI_HERE__|$CLI_HERE_BIN|g" \
    -e "s|__NVIM_HERE__|$NVIM_HERE_BIN|g" \
    -e "s|__PATH__|$INSTALL_PATH|g" \
    -e "s|__EDITOR__|$INSTALL_EDITOR|g" \
    "$TEMPLATE" >"$tmp_script"
  osacompile -o "$out" "$tmp_script"
  rm -f "$tmp_script"
}

if [[ -d "$APP" && $FORCE_BUILD -eq 0 ]]; then
  tmp_root="$(mktemp -d -t nvimhere)"
  build_app "$tmp_root/$APP_NAME.app"
  cp "$tmp_root/$APP_NAME.app/Contents/Resources/Scripts/main.scpt" \
    "$APP/Contents/Resources/Scripts/main.scpt"
  rm -rf "$tmp_root"
  echo "reusing: $APP (script patched, pass --force for a full rebuild)"
else
  rm -rf "$APP"
  mkdir -p "$(dirname "$APP")"
  build_app "$APP"
fi

plist="$APP/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$plist" >/dev/null 2>&1 || true; }

pb "Delete :CFBundleIdentifier"
pb "Add :CFBundleIdentifier string $BUNDLE_ID"
# Background shim: no Dock icon, no menu bar.
pb "Delete :LSUIElement"
pb "Add :LSUIElement bool true"

# Declare the doc types we handle. Without this, LaunchServices refuses to make
# us the default handler for anything, and duti fails with error -50.
pb "Delete :CFBundleDocumentTypes"
pb "Add :CFBundleDocumentTypes array"
pb "Add :CFBundleDocumentTypes:0 dict"
pb "Add :CFBundleDocumentTypes:0:CFBundleTypeName string Source text"
pb "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Editor"
pb "Add :CFBundleDocumentTypes:0:LSHandlerRank string Owner"
pb "Add :CFBundleDocumentTypes:0:LSItemContentTypes array"
for i in "${!UTIS[@]}"; do
  pb "Add :CFBundleDocumentTypes:0:LSItemContentTypes:$i string ${UTIS[$i]}"
done
# Extension declarations live in a separate dict with no LSItemContentTypes.
# When both keys sit in one dict, LaunchServices records the UTI claims and
# silently drops the extension bindings.
pb "Add :CFBundleDocumentTypes:1 dict"
pb "Add :CFBundleDocumentTypes:1:CFBundleTypeName string Source file"
pb "Add :CFBundleDocumentTypes:1:CFBundleTypeRole string Editor"
pb "Add :CFBundleDocumentTypes:1:LSHandlerRank string Owner"
pb "Add :CFBundleDocumentTypes:1:CFBundleTypeExtensions array"
for i in "${!EXTS[@]}"; do
  pb "Add :CFBundleDocumentTypes:1:CFBundleTypeExtensions:$i string ${EXTS[$i]}"
done

# public.folder is opt-in. Claiming it changes what `open .` and every app's
# "reveal in Finder" does for the whole system, which is a far bigger blast
# radius than "this file opens in nvim". Rank Alternate, not Owner: Owner on a
# type this broad would outrank every other claim.
if [[ $CLAIM_FOLDERS -eq 1 ]]; then
  pb "Add :CFBundleDocumentTypes:2 dict"
  pb "Add :CFBundleDocumentTypes:2:CFBundleTypeName string Folder"
  pb "Add :CFBundleDocumentTypes:2:CFBundleTypeRole string Viewer"
  pb "Add :CFBundleDocumentTypes:2:LSHandlerRank string Alternate"
  pb "Add :CFBundleDocumentTypes:2:LSItemContentTypes array"
  pb "Add :CFBundleDocumentTypes:2:LSItemContentTypes:0 string public.folder"
fi

# Icon. Copied in place rather than requiring a rebuild: deleting the bundle
# drops every association that points at it.
ICON_SRC="$HERE/assets/nvim.icns"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
  pb "Delete :CFBundleIconFile"
  pb "Add :CFBundleIconFile string AppIcon"
  pb "Delete :CFBundleIconName"
fi

# Editing Info.plist voids the ad-hoc signature osacompile applied.
codesign --force --sign - "$APP" 2>/dev/null

# A bundle without a usable identifier cannot be a LaunchServices handler.
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)" != "$BUNDLE_ID" ]]; then
  echo "error: CFBundleIdentifier missing from $plist" >&2
  exit 1
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP"
fi
echo "built: $APP ($BUNDLE_ID)"
sleep 1  # let LaunchServices finish ingesting the new bundle

# CLI companions. Symlinked, not copied: editing bin/ takes effect immediately
# and there is nothing to rebuild, so associations stay approved. Both names
# point at the same file; which one you call decides whether the rule table is
# read ($0 basename is the switch).
BIN_DIR="$HOME/.local/bin"
chmod +x "$HERE/bin/cli-here"
mkdir -p "$BIN_DIR"
ln -sf "$HERE/bin/cli-here" "$BIN_DIR/cli-here"
ln -sf "$HERE/bin/nvim-here" "$BIN_DIR/nvim-here"
echo "linked: $BIN_DIR/cli-here, $BIN_DIR/nvim-here"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "warn: $BIN_DIR is not in PATH; add it or call $HERE/bin/nvim-here directly" >&2 ;;
esac

if [[ $APPLY_DUTI -eq 0 ]]; then
  echo "skipped duti (--no-duti)"
  exit 0
fi

if ! command -v duti >/dev/null; then
  echo "error: duti not found. brew install duti" >&2
  exit 1
fi

# UTI-level only. One call covers many extensions (public.source-code alone
# covers ts/js/py/go/rs/...), so there are ~8 confirmation dialogs instead of 30.
for uti in "${UTIS[@]}"; do
  duti -s "$BUNDLE_ID" "$uti" all || echo "warn: $uti" >&2
done

# Folder claiming is decided by what LaunchServices currently says, not by a
# state file: this script rebuilds the plist every run, so a remembered flag
# would drift from reality.
if [[ $CLAIM_FOLDERS -eq 1 ]]; then
  duti -s "$BUNDLE_ID" public.folder all || echo "warn: public.folder" >&2
  echo "claimed: public.folder -> $BUNDLE_ID (undo: ./install.sh --no-claim-folders)"
elif duti -d public.folder 2>/dev/null | grep -q "$BUNDLE_ID"; then
  if [[ $CLAIM_FOLDERS -eq 2 ]]; then
    duti -s com.apple.finder public.folder all || true
    echo "released: public.folder -> com.apple.finder"
  else
    echo "note: public.folder is still claimed by $BUNDLE_ID from an earlier run" >&2
    echo "      release it with: ./install.sh --no-claim-folders" >&2
  fi
fi

echo
echo "spot check:"
for probe in md txt ts py js json yaml sh; do printf '  %-5s -> ' "$probe"; duti -x "$probe" 2>/dev/null | head -1; done
exit 0
