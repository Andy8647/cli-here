# ghostty-nvim-open

Point macOS file associations at Neovim running in the terminal, so Cmd+Click on a
file path in Ghostty (say `src/foo.ts` from pi output) opens `nvim` in a new tab of
the current window instead of launching VSCode.

The same program is callable from a shell as `cli-here`, which reads a rule table
and can send any path to any command: `nvim`, `yazi`, `hx`, the system default app,
or something that never needed a terminal at all.

## Why this exists

- `nvim` is a CLI tool. LaunchServices only accepts `.app` bundles, so there is no way
  to make it the default handler directly.
- Ghostty 1.4.1 hardcodes Cmd+Click on bare paths to the system `open`, ignoring
  `$EDITOR` (ghostty-org/ghostty#1972 is still an open feature request).
- The `link` config key added in 1.4.1 would be the real fix, but
  `ghostty +validate-config` still returns `link: error.NotImplemented`.

So the approach is a tiny AppleScript app acting as a LaunchServices middleman. It
receives files and hands them to `cli-here`, which owns every decision and asks
Ghostty for a new surface. `duti` then points the common text UTIs at the app.

## Prior art

Sending a file to a command chosen from a rule table is not a new idea. ranger's
`rifle.conf` is close enough to read side by side:

```text
# ranger's rifle.conf
ext pdf, has zathura, X, flag f = zathura "$@"
ext md,  has glow,    X, flag f = glow "$@"
```

- **`rifle`**, ranger's file launcher: a rule table with `ext` / `mime` / `has` /
  `X` conditions, evaluated top to bottom.
- **`handlr`** and **`handlr-regex`**: a standalone CLI for default handlers by
  extension or mime type, with regex handlers and `Terminal=true` entries.
- **`mimeo`**: the same idea, credited by `handlr-regex` for the regex part.

On Linux that is all you need, because the desktop itself accepts a command line as
a handler. macOS does not: LaunchServices only accepts a `.app` bundle, and `duti`
can only point a type at one of those. "Open `.pdf` with `zathura`" is not
expressible without writing an app first, which is why macOS tools in this space
tend to stop at *setting* a handler instead of *choosing a command*.

Ghostty has two open requests asking for the same thing from the other side, plus
a sibling terminal that shipped a partial version:

- [ghostty#1972](https://github.com/ghostty-org/ghostty/issues/1972): Cmd+Click
  should use `$EDITOR` instead of `open`. Long thread, no agreement on what the
  default should even be.
- [ghostty discussion #8327](https://github.com/ghostty-org/ghostty/discussions/8327):
  make Cmd+Click behave like Plan 9's plumbing, matching a regex and running a
  script. The examples there are literally `cmd+click /tmp/my.pdf` for Preview and
  clicking a log line for vim.
- A Ghostty-derived terminal, `cmux`, already ships a single
  `preferredEditorCommand` for Cmd+Click. One command, no rules.

What is different here is the combination: one rule table answers Finder
double-click, "Open With", Cmd+Click and `open -a`, because the table sits behind
a LaunchServices handler instead of inside the terminal. Every rule works with no
terminal involved at all, and a click that starts in Finder lands in the same
place as one that starts in Ghostty.

## Requirements

- macOS (built and tested on macOS 26 / Apple Silicon)
- [Ghostty](https://ghostty.org) 1.4 or newer
- Neovim in `PATH` for the default rules
- [`duti`](https://github.com/jrawit/duti): `brew install duti`

## Install

```fish
git clone https://github.com/Andy8647/ghostty-nvim-open
cd ghostty-nvim-open
bash install.sh
```

macOS will ask a few times whether all files of type `.<ext>` should open with
NvimHere. Click **Use**.

Four behaviours worth knowing:

- **Only the compiled script is swapped on reinstall.** `install.sh` recompiles into a
  temporary bundle and copies `main.scpt` into the installed one, so LaunchServices
  keeps every association and no approval dialog comes back. `--force` throws the
  bundle away and builds from scratch, which drops all of them.
- **Associations are set at UTI level** (`public.source-code`, `public.plain-text`,
  `net.daringfireball.markdown`, and so on). One UTI covers many extensions, which
  keeps the dialog count around 8 instead of 30+.
- **The app is a forwarder.** It bakes in three things at compile time (the absolute
  path of `bin/cli-here`, your `PATH`, and your `EDITOR`) and passes every click to
  the CLI. Changing a rule, or `cli-here` itself, never means rebuilding the bundle.
- **`public.folder` is opt-in.** See [Folders](#folders).

Changing the PATH the app hands over, the AppleScript, the icon, or the set of
claimed types: edit, then rerun `bash install.sh`. Nothing needs `--force` unless
the bundle itself is broken.

## Rules

`cli-here` reads `~/.config/cli-here/config`. No config file means it behaves
exactly like `nvim-here`, so writing nothing changes nothing.

Copy [`config.example`](config.example) to get started:

```fish
mkdir -p ~/.config/cli-here
cp config.example ~/.config/cli-here/config
$EDITOR ~/.config/cli-here/config
cli-here --dry-run README.md     # see what a path would do, without opening it
```

One rule per line, `MATCHER => ACTION`, **first match wins**. Blank lines and lines
starting with `#` are ignored.

| Matcher | Matches |
|---|---|
| `dir` | a directory |
| `noext` | a file with no extension: `Makefile`, `.gitignore`, `trail.` |
| `ext:md,ts,tsx` | extension, case-insensitive. `foo.d.ts` counts as `ts` |
| `glob:**/migrations/*.sql` | a glob against the absolute path |
| `*` | everything; keep it last |

Inside a `glob:`, `*` does not cross a `/`, `**` does, `**/` also matches zero
directories, and `?` is one character. A pattern that starts with neither `/` nor
`~/` matches at any depth.

| Action | What happens |
|---|---|
| `nvim {loc}` | a new Ghostty surface; `-b`, `-w` and `--split` apply |
| `@run cmd {files}` | runs here, no terminal, waits, passes the exit code through |
| `@open` | hands the paths to whatever app the system would use |

| Placeholder | Means |
|---|---|
| `{files}` | every path of the group, one argument each; must stand alone |
| `{file}` | one path; makes the action run once per file |
| `{loc}` | `path`, `path:LINE` or `path:LINE:COL` |
| `{line}` `{col}` | the number; an argument containing it disappears when there is none |
| `{dir}` | `-C`, or the folder of the opened file when the click came from Finder |

Paths are substituted **after** the action is split into words, so a file name with
a space, a quote or a `$` in it can never become a second argument. Quoting is only
single and double quotes: no escapes and no variable expansion.

Files that land on the same rule are grouped, in the order they first appear, so
`cli-here a.md b.md x.pdf` opens one nvim tab with both markdown files and one
Preview for the PDF. An action using `{file}` or `{loc}` runs once per file instead.

A bad config is rejected whole, with a line number:

```text
cli-here: /Users/andy/.config/cli-here/config:6: {file} cannot share an argument with {line} or {col}; use {loc}
```

Skipping one broken rule would let the rules below it catch files that were never
meant for them, which routes silently to the wrong app.

### @open and loops

`.md`, `.txt` and most of the claimed types already point at NvimHere, so `@open` on
them would come straight back: `open` → app → `cli-here` → `open`. LaunchServices
passes no environment, so a re-entry flag cannot be carried through it.

Instead, before opening anything, `cli-here` asks the system which app would handle
the path (`NSWorkspace.URLForApplicationToOpenURL`, about 50ms). If the answer is
NvimHere itself, it opens nvim instead and says so:

```text
cli-here: note: /repo/a.md is handled by NvimHere itself; opening nvim instead
```

A bare `open {file}` in a rule is refused at parse time for the same reason.

## CLI

`install.sh` symlinks both `bin/cli-here` and `bin/nvim-here` into `~/.local/bin`.
They are the same file; the name decides the behaviour.

```fish
nvim-here                      # nvim in a new tab, cd'd to the current directory
nvim-here src/foo.ts:42        # jump to line 42
nvim-here src/foo.ts:42:7      # ...and column 7
nvim-here -C ~/repo a.md b.py  # cd first, open two files
nvim-here --new-window README.md
nvim-here --split=down src/foo.ts   # split the focused pane, like Cmd+D
nvim-here -b --split=down src/foo.ts  # ...without taking the keyboard
nvim-here --hold broken.sh     # keep the tab after the command exits

cli-here README.md             # read the rule table
cli-here --dry-run README.md src   # print the plan, open nothing
```

- **`nvim-here` never reads the config.** It always runs nvim, and it is the escape
  hatch when a rule table goes wrong, so it has to keep working.
- **`cli-here` with no config file is the same as `nvim-here`.**
- **`cli-here` with a config and no arguments** targets the working directory, which
  is how `dir => yazi {files}` opens a file manager.
- **`--dry-run`** prints the plan: one block per action, with the rule that chose it
  and the exact argv. It is also the config checker.

```text
surface mode=tab bg=0 cwd=/repo label=foo.ts rule=config:2
  /opt/homebrew/bin/nvim
  +42
  +call cursor(42,7)
  --
  /repo/foo.ts
```

A `:LINE` suffix is only stripped when the bare path exists, so `test:2024.log`
stays a filename. The jump applies to the first file of the group, since nvim runs
its `+cmd` after the first buffer loads; a later `:LINE` is dropped with a note.

`--split` takes `right` (default, the Cmd+D direction), `down`, `left` or `up`.
`-b` keeps the keyboard where it was: a tab is created unselected, and for a split
focus is handed back to the pane you came from. `--hold` sets `wait after command`,
so a tool that dies on startup leaves its output on screen.

Tabs are named after what was opened (`foo.ts`, `foo.ts +2`, or the directory),
not after Ghostty's 👻 placeholder. A surface started with `command` never runs
a shell, and the tab title normally comes from shell integration.

Unlike the app, the CLI is not limited to the extensions in `EXTS`, so it also
covers directories, `Makefile`, extensionless scripts, and files in repos that
have no associations at all. It reaches Ghostty over AppleScript instead of
LaunchServices, so the first caller that has never driven Ghostty will trigger a
one-time automation permission prompt (from Ghostty itself there is none).

## Folders

Cmd+Click on an absolute directory path does reach the handler, so `dir` rules work
from a click as well as from the CLI. Claiming `public.folder` is a separate,
opt-in step because it changes what `open .` and every app's "reveal in Finder" do
for the whole system:

```fish
bash install.sh --claim-folders      # declare it and point public.folder at the app
bash install.sh --no-claim-folders   # hand it back to Finder
```

The rank for that claim is `Alternate`, not `Owner`: a type this broad must not
outrank other apps' claims. `uninstall.sh` always gives folders back to
`com.apple.finder`, never to the editor the extensions are restored to.

## Uninstall

```fish
bash uninstall.sh
```

Defaults to handing the associations back to VSCode:

```fish
bash uninstall.sh --to com.apple.TextEdit   # hand them to TextEdit instead
bash uninstall.sh --keep-app                # restore associations, keep the .app
```

## Tests

```fish
bash tests/run.sh
```

Runs every suite under `/bin/bash` (3.2) and Homebrew bash, then shellcheck:

| Suite | Covers |
|---|---|
| `tests/golden.sh` | the observable behaviour of `nvim-here`, 63 cases, recorded against the pre-rule-table version |
| `tests/template.sh` | tokenizing, placeholder validation, expansion |
| `tests/plan.sh` | config parsing, matchers, error messages, the plan |
| `tests/actions.sh` | grouping, `@run`, `@open`, loop protection, what a surface is told |
| `tests/quoting.sh` | real osascript `quoted form` + real `bash -c "exec -l"`, byte for byte |
| `tests/forward.sh` | the app's forwarder, driven through `load script` |

## Layout

```
src/NvimHere.applescript   # forwarder; the four __PLACEHOLDERS__ are filled at install
bin/cli-here               # rules, plan, execution
bin/nvim-here              # symlink to cli-here; the config-free entry point
config.example             # the rule table, with every matcher and placeholder
assets/nvim.icns           # app icon (official Neovim mark on a macOS squircle)
assets/make-icon.sh        # regenerate it: neovim-mark.svg -> nvim.icns
tools/set-browser.swift    # reset the default browser / http(s) handlers
install.sh                 # compile app + register with LaunchServices + set handlers
uninstall.sh               # restore handlers (VSCode by default)
tests/                     # see above
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

- The CLI builds a plan first and executes second. `build_plan` only reads: it stats
  paths, matches rules, resolves the tool with `type -P` (so a shell function or
  alias can never be picked up) and fills parallel arrays. `execute_plan` is the only
  code with side effects, which is what makes `--dry-run` a real check rather than a
  simulation.
- Ghostty runs `command` through `/bin/bash -c` with the minimal GUI PATH, and that
  wrapper is literally `exec -l <command>`. The command string must therefore be one
  executable plus arguments: `cd /repo && nvim foo` silently starts nothing, because
  `cd` is a shell builtin and `exec` cannot run it. The working directory has to come
  from the surface configuration's `initial working directory`.
- A surface is told only two environment variables, `PATH` and `EDITOR`, through the
  sdef's `environment variables`. Ghostty merges them into the inherited environment
  rather than replacing it, so `HOME`, `TERM` and `LANG` survive. Forwarding the whole
  environment would hand every secret in the caller's shell to every surface.
- The CLI passes the tool path and arguments as `argv` to AppleScript, which quotes
  each one with `quoted form of`. Paths never depend on how the caller's shell quoted
  them, and a path with a newline in it still arrives as one argument.
- argv layout between the CLI and its embedded AppleScript: tool, cwd, mode, split,
  background, label, hold, `PATH=` assignment, `EDITOR=` assignment, then the tool's
  arguments. An empty cwd means "leave the surface where Ghostty puts it", which is
  what `--from-ls` uses; an empty assignment is skipped.
- The AppleScript must say `new tab in w with configuration cfg`. Plain `new tab`
  fails with `-1708 Can't continue new tab`.
- The app sets `LSUIElement`, so it stays out of the Dock and Cmd+Tab.
- The bundle is still `NvimHere.app` with `dev.andy.nvimhere`, even though the tool
  is now `cli-here`. Renaming either one drops every LaunchServices association and
  every approval, which is a bad trade for a name nobody types.
- Titles: `command` surfaces bypass the shell, so shell integration never reports a
  title and Ghostty keeps its 👻 placeholder. The CLI sets `name override` on the new
  tab (file name, `foo.ts +2`, or the directory). nvim only sends a title of its own
  when `set title` is on, so nothing is being shadowed.
- Icon updates only copy the file and re-sign, they never remove the bundle, so
  approved associations survive.
- `LSHandlerRank` is `Owner` for the text types. With `Default`, Obsidian holds on to
  `net.daringfireball.markdown` and the user preference is ignored.
- Errors are appended to `~/Library/Logs/NvimHere.log`, and the app shows the same
  text in an alert, because a click has no terminal to print to.

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
- Ghostty only turns absolute paths into clickable links. A relative path in the
  terminal (`assets/`) is not a link, so it never reaches a handler; use the CLI.
- `@run` is meant for commands that return quickly. Anything long-running belongs in
  a surface, where you can see it and interrupt it.

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
