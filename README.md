# ghostty-nvim-open

Point macOS file associations at Neovim running in the terminal, so Cmd+Click on a
file path in Ghostty (say `src/foo.ts` from pi output) opens `nvim` in a new tab of
the current window instead of launching VSCode.

## Why this exists

- `nvim` is a CLI tool. LaunchServices only accepts `.app` bundles, so there is no way
  to make it the default handler directly.
- Ghostty 1.4.1 hardcodes Cmd+Click on bare paths to the system `open`, ignoring
  `$EDITOR` (ghostty-org/ghostty#1972 is still an open feature request).
- The `link` config key added in 1.4.1 would be the real fix, but
  `ghostty +validate-config` still returns `link: error.NotImplemented`.

So the approach is a tiny AppleScript app acting as a LaunchServices middleman: it
receives files and asks Ghostty to open a new tab running nvim. `duti` then points the
common text UTIs at it.

## Requirements

- macOS (built and tested on macOS 26 / Apple Silicon)
- [Ghostty](https://ghostty.org) 1.4 or newer
- Neovim in `PATH`
- [`duti`](https://github.com/jrawit/duti): `brew install duti`

## Install

```fish
git clone https://github.com/Andy8647/ghostty-nvim-open
cd ghostty-nvim-open
bash install.sh
```

macOS will ask a few times whether all files of type `.<ext>` should open with
NvimHere. Click **Use**.

Two behaviours worth knowing:

- **Only the compiled script is swapped on reinstall.** `install.sh` recompiles into a
  temporary bundle and copies `main.scpt` into the installed one, so LaunchServices
  keeps every association and no approval dialog comes back. `--force` throws the
  bundle away and builds from scratch, which drops all of them.
- **Associations are set at UTI level** (`public.source-code`, `public.plain-text`,
  `net.daringfireball.markdown`, and so on). One UTI covers many extensions, which
  keeps the dialog count around 8 instead of 30+.

Changing the nvim path, the AppleScript, the icon, or the set of claimed types: edit,
then rerun `bash install.sh`. Nothing needs `--force` unless the bundle itself is
broken.

## CLI

`install.sh` also symlinks `bin/nvim-here` into `~/.local/bin`. Same tab, same
nvim, but callable from a shell, a keybinding, or an agent: any path, any
extension, and an optional line number.

```fish
nvim-here                      # nvim in a new tab, cd'd to the current directory
nvim-here src/foo.ts:42        # jump to line 42
nvim-here src/foo.ts:42:7      # ...and column 7
nvim-here -C ~/repo a.md b.py  # cd first, open two files
nvim-here --new-window README.md
nvim-here --split=down src/foo.ts   # split the focused pane, like Cmd+D
nvim-here -b --split=down src/foo.ts  # ...without taking the keyboard
```

A `:LINE` suffix is only stripped when the bare path exists, so `test:2024.log`
stays a filename. The jump applies to the first file only, since nvim runs its
`+cmd` after the first buffer loads.

`--split` takes `right` (default, the Cmd+D direction), `down`, `left` or `up`.
`-b` keeps the keyboard where it was: a tab is created unselected, and for a
split focus is handed back to the pane you came from, so an agent can drop a
file next to you without stealing the cursor.

Tabs are named after what was opened (`foo.ts`, `foo.ts +2`, or the directory),
not after Ghostty's 👻 placeholder. A surface started with `command` never runs
a shell, and the tab title normally comes from shell integration.

Unlike the app, the CLI is not limited to the extensions in `EXTS`, so it also
covers directories, `Makefile`, extensionless scripts, and files in repos that
have no associations at all. It reaches Ghostty over AppleScript instead of
LaunchServices, so the first caller that has never driven Ghostty will trigger a
one-time automation permission prompt (from Ghostty itself there is none).

## Uninstall

```fish
bash uninstall.sh
```

Defaults to handing the associations back to VSCode:

```fish
bash uninstall.sh --to com.apple.TextEdit   # hand them to TextEdit instead
bash uninstall.sh --keep-app                # restore associations, keep the .app
```

## Layout

```
src/NvimHere.applescript   # the middleman; __NVIM__ becomes an absolute path at install
bin/nvim-here              # CLI twin: paths, :LINE, -C DIR, --split, -b
assets/nvim.icns           # app icon (official Neovim mark on a macOS squircle)
assets/make-icon.sh        # regenerate it: neovim-mark.svg -> nvim.icns
tools/set-browser.swift    # reset the default browser / http(s) handlers
install.sh                 # compile app + register with LaunchServices + set handlers
uninstall.sh               # restore handlers (VSCode by default)
```

## Icon

![NvimHere icon](assets/preview.png)

The icon lives in `assets/nvim.icns`: a 1024 canvas with an 824 rounded square of
radius 185, official Neovim mark centred on top. To change it:

```fish
cd assets
bash make-icon.sh          # regenerate nvim.icns
cd .. && bash install.sh   # copies it in place, no rebuild, associations survive
```

Finder caches icons aggressively; `killall Finder` refreshes it.

## Implementation notes

- Ghostty runs `command` through `/bin/bash -c` with the minimal GUI PATH, so nvim is
  referenced by absolute path. `bin/nvim-here` passes nvim, the target directory and
  the files as `argv` to AppleScript, which quotes each one with `quoted form of`, so
  spaces and CJK paths never depend on how the caller's shell quoted them.
- That wrapper is literally `exec -l <command>`, so the command string must be one
  executable plus arguments. `cd /repo && nvim foo` silently starts nothing: `cd` is a
  shell builtin, `exec` cannot run it, and the `&&` never gets a second chance. The
  working directory has to come from the surface configuration's
  `initial working directory` instead.
- The AppleScript must say `new tab in w with configuration cfg`. Plain `new tab`
  fails with `-1708 Can't continue new tab`.
- The app sets `LSUIElement`, so it stays out of the Dock and Cmd+Tab.
- Titles: `command` surfaces bypass the shell, so shell integration never reports a
  title and Ghostty keeps its 👻 placeholder. Both the app and the CLI set
  `name override` on the new tab (file name, `foo.ts +2`, or the directory). nvim only
  sends a title of its own when `set title` is on, so nothing is being shadowed.
- Icon updates only copy the file and re-sign, they never remove the bundle, so
  approved associations survive.
- `LSHandlerRank` is `Owner`. With `Default`, Obsidian holds on to
  `net.daringfireball.markdown` and the user preference is ignored.
- Errors are appended to `~/Library/Logs/NvimHere.log`.

## Never associate HTML

`public.html` is not just a file type. macOS treats the HTML handler as the system
default browser (`com.apple.default-app.web-browser`, plus the `http` and `https`
URL schemes). If this shim claims HTML, every web link gets handed to it and opens
nothing. `install.sh` refuses to run if `public.html` is ever added to the UTI list.

If the browser gets clobbered anyway:

```fish
swift tools/set-browser.swift com.google.chrome
```

The `.html` / `.htm` extensions are still claimed, which only affects double-clicking
an HTML file; it does not touch the browser setting.

## Known limits

- Ghostty blocks Cmd+Click on local targets it considers executable (`.sh`,
  `.command`). There is no config key to disable that, so clicking a script path
  shows "Ghostty Blocked This Link". Double-clicking the same file in Finder still
  works, since that path does not go through Ghostty.

## Replacement for an installed editor

This setup is meant to survive removing VS Code. Two things make that work:

- The app declares each extension itself, in a `CFBundleDocumentTypes` entry with no
  `LSItemContentTypes` and `LSHandlerRank = Owner`. Extensions nobody declares
  resolve to throwaway `dyn.*` types, and LaunchServices will not store a default
  handler for those. When both keys sit in one dict, the extension bindings are
  silently dropped.
- `duti` still has to overwrite explicit per-type preferences left by the previous
  editor (`public.bash-script`, `public.objective-c-source`, and friends). Those
  override declaration ranking no matter what the rank says.

After removing the old editor, rebuilding the LaunchServices database clears its
stale claims:

```fish
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -kill -r -domain local -domain system -domain user
bash install.sh
```

## License

MIT. See [LICENSE](LICENSE).
