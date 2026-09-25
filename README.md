# zsh-smart-complete

> A modern smart completion & suggestion layer for Zsh.
> Engineered as the frontend of a future independent shell.
>
> **v2.4.0** — The installers stopped treating a mirror URL as code, an install that fails halfway rolls itself back, and `./install.sh --uninstall` (or `SMART_UNINSTALL=1`) removes exactly what was written. The opt-in vertical completion list now holds its shape while you type: commands still come after `|`, `&&`, `;` and a wrapper like `sudo`, and `cd`'s recent directories answer a typed prefix — and a `#` you type is a literal, not a pattern. `tests/` gained three suites, plus a linter that makes every new global justify itself.

[English](./README.md) · [简体中文](./README.zh-CN.md) · [繁體中文](./README.zh-TW.md) · [日本語](./README.ja.md) · [한국어](./README.ko.md)

## Status

| Channel | Status |
| ------- | ------ |
| Build & test (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| Release | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| Version | 2.4.0 |

## Why

Replaces both `zsh-autocomplete` and `zsh-autosuggestions` in a single plugin with a clean modular architecture, designed to evolve into a standalone shell.

- **Two halves, one engine (v2.2.0)** — while you type, the candidate list pops up *immediately* (the `zsh-autocomplete` behaviour) while the inline grey suggestion stays; `→` accepts it all, `Alt+→` accepts one word (the `zsh-autosuggestions` behaviour). One plugin, one keymap, two channels — the real fix for "the two plugins conflict".
- **Zero external dependencies** — the core plugin is self-contained; Atuin is optional.
- **Every arrow-key encoding is bound** — both `ESC [ C` and `ESC O C` (application cursor-keys mode, what `TERM=xterm-256color` actually sends) are bound, so you never get "grey text shows but the arrow does nothing".
- **Syntax-highlighting friendly** — claims at most one `region_highlight` entry, tagged `memo=zsh-smart-complete:suggestion`, and removes only that entry, so other highlighters are never clobbered.

## Architecture

```
              zsh-smart-complete.plugin.zsh
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
      config            state             event/zle
         │                 │                 │
         └─────────────────┼─────────────────┘
                           │
               ┌───────────┴───────────┐
               │                       │
         engine/suggest          engine/native
               │                       │
        history/history         (user compinit)
                                       │
                                   engine/menu
                              (type-to-popup list)
               │
      zsh fc   │   atuin (opt)   │   smart-engine (future)
               └───────────────────┴───────────────────┘
                           │
                     display/
                 region_highlight
```

## Quick start

### Prerequisites

Make sure Zsh itself has `compinit`:

```zsh
export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=1000000
export SAVEHIST=1000000
setopt appendhistory sharehistory histignorealldups

autoload -Uz compinit
compinit
```

### Install

> ⚠️ This plugin replaces **both** `zsh-autocomplete` and `zsh-autosuggestions`.

#### Method A — one-line installer (recommended)

```zsh
curl -fsSL https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh | bash
```
Prompts are read from `/dev/tty`, so the interactive menus still work even though stdin is the script itself.

#### Method B — Zinit

```zsh
zinit light imonior/zsh-smart-complete
```

#### Method C — manual clone

```zsh
git clone https://github.com/imonior/zsh-smart-complete.git ~/.zsh-smart-complete
echo 'source ~/.zsh-smart-complete/zsh-smart-complete.plugin.zsh' >> ~/.zshrc
```

#### Mainland-China mirror

The installer auto-detects your public-IP region and reports it. The region decides **which candidates are worth showing**: mainland China / not detected show every candidate and speed-test every candidate including direct (whether direct is really faster should be measured, not guessed from geography); **outside mainland China hides every preset mirror** and keeps only direct — those ghproxy / gitclone channels are mainland-only and are often slower than direct out there. Even outside mainland China, though, **direct is still speed-tested**, and both manual entries are always available: a **mirror source** (rewrites GitHub URLs) or a **full proxy** (exported as `HTTP_PROXY`/`HTTPS_PROXY` so curl/git/wget route everything through it, e.g. `http://127.0.0.1:7890`). Preset mirrors are labelled *China mainland only*. The snippets below are only needed for non-interactive installs. A mirror you enter by hand — or pass as `SMART_INSTALL_GH_MIRROR` — has to be an `https://` URL: that is the address the fetched scripts get executed through, so plaintext `http://` is refused rather than trusted.

```zsh
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh | SMART_INSTALL_GH_MIRROR=https://ghproxy.net/ bash
```

## Configuration

Set these variables **before** the plugin loads:

```zsh
# Master switch
: ${SMART_ENABLED:=true}
# Engines
: ${SMART_SUGGEST:=true}
: ${SMART_COMPLETE:=true}
: ${SMART_SUGGEST_STRATEGY:=history,completion}  # history,completion | history (combined default: completion fills gaps when history has no match)
# History backend: zsh | atuin | smart-engine (future)
: ${SMART_HISTORY_BACKEND:=zsh}
# UI
: ${SMART_INLINE:=true}
: ${SMART_SUGGEST_COLOR:=auto}       # "auto" = fg=110 on 256-colour terms, fg=8 otherwise

# Type-to-popup candidate list (the zsh-autocomplete half)
: ${SMART_MENU:=true}
: ${SMART_MENU_MIN_PREFIX_CMD:=2}     # min chars in the COMMAND word before listing
: ${SMART_MENU_MIN_PREFIX:=2}         # min chars in an ARGUMENT word, counted after
                                      # the last "/" (0 = also right after a space)
: ${SMART_MENU_MIN_MATCHES:=1}        # min candidates before the live popup (1 = a single match also pops, like autocomplete)
: ${SMART_MENU_MAX_MATCHES:=100}       # more candidates than this -> no list (keeps huge dirs, and zsh's "see all N possibilities" prompt, away)
: ${SMART_MENU_MAX_PREFIX:=64}
: ${SMART_MENU_HISTORY_KEYS:=false}  # true = up/down prefix-search history while the line is non-empty
: ${SMART_MENU_SINGLE_COLUMN:=false} # true = ONE candidate per line (opt-in: loses descriptions/colours/fuzzy); false = zsh's grid
: ${SMART_MENU_LISTER:=builtin}       # WHO draws the list: builtin = this plugin; fzf-tab = stop drawing, let an external picker own it
# Throttle: OFF by default. Measured cost is only 10-30ms per listing, so there is
# nothing to throttle; this knob is for a *persistently* expensive completion. When
# on, a listing >= SLOW_MS buys COOLDOWN_KEYS skipped edits. Note: a skipped edit is
# not repainted, so the on-screen list vanishes for that keystroke — which is exactly
# why the default is 0.
: ${SMART_MENU_SLOW_MS:=250}
: ${SMART_MENU_COOLDOWN_KEYS:=0}

# Debugging: set to a file path and every tick decision (gate refused / cooldown
# swallowed / match count / measured cost) is appended there. "The popup didn't
# appear" is otherwise indistinguishable from "one match, so the ghost took over".
: ${SMART_MENU_DEBUG:=}

# Recent directories: while completing `cd`, offer the directories you have
# actually been in, and list them immediately on the EMPTY word after `cd `
# (the one place where an empty word is worth listing). Read-only — it consumes
# zsh's own recent-dirs database and never records anything itself.
: ${SMART_RECENT_PATHS:=true}
: ${SMART_RECENT_PATHS_MAX:=20}
```

Named widgets are exposed too, so you can rebind them the way you would with
`zsh-autosuggestions`: `smart-accept-suggestion` (accept the whole suggestion,
bound to the right arrow), `smart-accept-word` (accept one word, bound to
Alt+right-arrow), `smart-execute-suggestion` (accept, then run the line) and
`smart-suggestion-toggle` (turn the grey ghost on/off). With
`SMART_MENU_HISTORY_KEYS=true`, up/down prefix-search your history while the line
is non-empty — off by default, because those keys carry strong muscle memory.

## Optional extras

### Fuzzy matching (done by zsh, not by us)

The live popup runs *your* completion system, so any matcher you configure
applies to it automatically. To let `fb` match `foobar.txt`:

```zsh
zstyle ':completion:*' matcher-list 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
```

There is nothing to switch on here — and no fuzzy-matching code on our side,
which would only fight the completion system.

### Single-column popup (opt-in)

`SMART_MENU_SINGLE_COLUMN=true` draws the type-to-popup as **one candidate per
line** instead of zsh's native multi-column grid. It is **off by default, and
deliberately so** — worth reading before you turn it on:

- A vertical list can only be drawn by **generating** the candidates (there is no
  reliable way to capture compsys' own: shadowing `compadd` with a function makes
  several zsh builds stop adding matches entirely — measured). So this mode
  **bypasses `_main_complete`**, and for the contexts it covers you lose candidate
  **descriptions**, `list-colors` colouring, grouping, and your
  `zstyle ':completion:*' matcher-list` — the documented fuzzy matching does
  **not** apply to generated candidates.
- Only commands / functions / aliases / builtins, filesystem paths and `cd`
  recent directories are generated. Commands are generated wherever the shell is
  still choosing one — the first word, and the word after `|`, `&&`, `;` or a
  bare wrapper like `sudo`; the recent directories answer a typed prefix, not
  only an empty word. Everything else (git subcommands, ssh hosts, `--options`,
  `~user`, and anything after a wrapper that already took a command, like
  `sudo git`) produces nothing here and falls through to the native
  grid, so **the popup changes shape while you type** — easily mistaken for a
  second list appearing.
- A candidate wider than the terminal is clipped to one line (no ellipsis).

The mechanism is arithmetic: every *display* string is padded — or clipped — to
exactly `COLUMNS` wide, so exactly one column fits. The typed word is escaped
before it becomes a glob or a prefix pattern, so a `[` in a filename cannot
break the popup and a `#` cannot widen it into a pattern (a leading `~/` stays
unescaped, so `~/…` candidates keep working).

### Recent directories

While completing a `cd` / `pushd` / `chdir` argument, the directories you have
actually been in are offered as candidates, and they are listed immediately on
the **empty word** after `cd ` (the one place where an empty word is worth
listing).

The data is zsh's own recent-directories database — the same one `cdr` and `~[1]`
use. The plugin only *reads* it and never writes anything. If yours is still
empty, two lines turn collection on:

```zsh
autoload -Uz chpwd_recent_dirs add-zsh-hook
add-zsh-hook chpwd chpwd_recent_dirs
```

`smart-recent status` reports how many entries are usable right now.

### Which lister draws the list? (the 2-choose-1)

Two completion listers are both entitled to draw, so two lists appearing at once
is not a bug either of them can fix — one of them has to stop. `SMART_MENU_LISTER`
picks the owner:

| value | what happens |
|---|---|
| `builtin` (default) | this plugin drives zsh's list, as before |
| `fzf-tab` | this plugin **draws nothing**; the external floating picker is the only list on screen |

It does not install fzf-tab — it makes *this* plugin stop listing so that
whatever other lister you run is the only one drawing. The inline grey
suggestion is untouched: only the candidate list is handed over. With `fzf-tab`
we also stop setting `zstyle ':completion:*' menu select` in the Tab widget,
because zsh's selectable menu is itself a list drawer competing for the same
screen.

```zsh
smart-lister                       # who owns the list right now?
smart-lister builtin | fzf-tab     # switch it for this shell
```

The accepted spellings are:

| spells this plugin | spells "hand it over" |
|---|---|
| `builtin` `smart` `internal` `native` `built-in` `on` `yes` `true` `1` | `fzf-tab` `fzf_tab` `fzf` `ftb` `external` `none` `off` `no` `false` `0` |

`off` means "**our** lister off" — i.e. hand it over — not "no list at all",
which is what `SMART_MENU=false` is for. An unrecognised value falls back to
`builtin` (a typo must not silently kill the popup) and is reported as
unrecognised; a mistyped *argument* to `smart-lister` is rejected with a
non-zero status, so `smart-lister fzf-tb` can no longer look like a successful
switch.

When it goes wrong, `smart-doctor` is the answer: it prints the current owner,
and if the list has been handed to a picker that is **not loaded** it says so and
makes that its verdict — because "nothing is drawn at all" is a worse state than
two lists.

### Two candidate lists at once?

If two lists appear on screen at the same time, `smart-doctor` prints the
fingerprints of every known lister, so the question becomes readable instead of
arguable:

```zsh
smart-doctor
```

It reports whether `_main_complete` / `compadd` / `_complete` are still zsh's
stock entry points, whether `zsh-autocomplete` / `zsh-autosuggestions` /
`fzf-tab` / syntax-highlighting are loaded, who owns `Tab` in each keymap, the
zstyles that can enable a list, and this plugin's own state — then a verdict.
It is read-only, so it is safe to run in a half-broken shell.

### Interactive installer options

The installer asks about every optional piece — fzf-tab, the single-column
layout, recent directories, Up/Down history search, zsh-vi-mode and the
suggestion source — and writes your answers into a managed block in `~/.zshrc`.
The block sits *above* the plugin load on purpose: options such as
`SMART_MENU_HISTORY_KEYS` are read while the plugin installs its key bindings,
so writing them afterwards would be silently ignored. Re-running rewrites only
that block; `NONINTERACTIVE=1` takes the documented defaults.

fzf-tab is opt-in (default **off**) and, when enabled, forces the built-in
selectable menu off: both are completion *listers*, and running two at once is
exactly how you end up with two popups fighting over the same screen area.

## Runtime commands

```zsh
smart-status      # print current state + config
smart-disable     # disable the plugin
smart-enable      # re-enable
smart-reindex     # force a history index rebuild
smart-menu on     # turn the type-to-popup list on
smart-menu off    # turn it off (inline ghost text unaffected)
smart-menu status # show menu config + last listing result
smart-doctor      # print every fingerprint of a SECOND candidate list (another lister)
smart-lister builtin|fzf-tab  # choose WHICH lister owns the list (fzf-tab = we stop drawing)
smart-recent on|off|status # recent-dir candidates + `cd ` empty-word listing
```

## Local settings script

The installer creates a user settings file and a small CLI to manage it, so you
can tune the plugin without ever touching `~/.zshrc`. The file lives at:

```
${SMART_USER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh-smart-complete/settings.zsh}
```

Run `zsc-settings` (the installer symlinks it into `~/.local/bin/zsc-settings`, so
make sure that directory is on your `PATH`, or call the script by its full path)
any time after install:

| Command | What it does |
| --- | --- |
| `zsc-settings` | interactive wizard — pick a setting, type a new value |
| `zsc-settings list` | every setting with its effective (current) value |
| `zsc-settings get KEY` | print one setting's effective value |
| `zsc-settings set KEY VALUE` | validate + write one setting |
| `zsc-settings edit` | open the file in `$EDITOR` |
| `zsc-settings reset [KEY]` | drop one override (or all) → back to default |
| `zsc-settings path` | print the settings file path |
| `zsc-settings init` | (re)create the file with commented defaults |

Values are written as plain `KEY='VALUE'` lines. The plugin sources this file
**before** its built-in defaults, so anything you write overrides the default.
After changing a value, **restart zsh** (e.g. `exec zsh`) for it to take effect.
`set` validates the value against the setting's type (bool / int / enum / path)
and refuses invalid input. To use a different file, point `SMART_USER_CONFIG` at
it before zsh starts.

## Uninstall

```zsh
./install.sh --uninstall
# over the one-liner, where argv does not survive the pipe:
curl -fsSL https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh | SMART_UNINSTALL=1 bash
```

It removes exactly what the installer wrote — the two managed blocks in
`~/.zshrc`, the plugin checkout, `settings.zsh` and the `zsc-settings` symlink —
and it asks before touching anything (a headless run counts `SMART_UNINSTALL=1`
as the confirmation). `~/.zshrc` is copied to `~/.zshrc.bak.<timestamp>` first,
and the uninstall refuses to edit it if that copy cannot be made.

Packages the installer may have installed (fzf, starship, atuin, zinit) stay
installed, and so do your `starship.toml` and every `.bak.*` file: they belong to
the shell, not to this plugin. Restart zsh afterwards.

## Changelog

See [CHANGELOG](./CHANGELOG.md) for the full history. The GitHub Release notes are extracted from these multi-language CHANGELOG files (en / zh-CN / zh-TW / ja / ko).

## Testing

```zsh
./tests/run-all.sh            # every suite, one line each
./tests/run-all.sh -v         # ... with full output
./tests/run-all.sh menu       # only suites whose name matches
./tests/run-all.sh --list     # what would run
```

`tests/run-all.sh` **discovers** `tests/test-*.zsh` (run with zsh) and
`tests/test-*.sh` (run with bash), so adding a test file needs no other edit —
the CI job used to list all twelve by hand, next to a comment admitting that a
new file nobody added there is silently never run. It also sums the suites'
assertion tallies, so the reported count is a measured number on every run.

One suite, `tests/test-perf.zsh`, asserts wall-clock caps instead of behaviour:
every quadratic-complexity bug this project has fixed produced perfectly
correct output, and the only symptom was seconds.

`install.sh` and `install-entware.sh` each contain one block generated from
`lib/install/core.sh` (the functions that are identical in both installers), which
is why the two files stay standalone enough for `curl … | bash`. To change that
shared behaviour: edit `lib/install/core.sh`, run `tools/build-installers.sh`, and
commit both installers. `tools/build-installers.sh --check` is what CI runs;
`tests/test-installer-shared.sh` covers the rest of the contract between the two
files, including the list of duplications that remain on purpose.

**Test summary:** `./tests/run-all.sh` runs every suite and prints the file and
assertion counts it measured; on ubuntu-latest the run is green with 1366
assertions and 0 failures.
The installer also now **scans other startup files** (`.zprofile`, `.zshenv`, `conf.d/*.zsh`, `.zshrc.d/*`, `/etc/zsh/zshrc`) for left-over loaders of `zsh-autocomplete` / `zsh-autosuggestions` after cleaning `~/.zshrc`, and **warns** (with exact `file:line`) if it finds any — it never edits those files. See CHANGELOG `[v2.2.5]`.


Key behaviours are additionally verified end-to-end against a real `zsh -i` in a
tmux pane, asserting on the rendered screen. That suite scored
**24/49 on v2.1.6** back when it held 49 assertions — one of those 49 is not even
reached there, because its section stops after a failure — while the two
scenarios added since check the single-column list, which v2.1.6 does not draw at
all. On that version the type-to-popup does not exist, the `SS3` and
`Alt+→` encodings are dead, `Tab` followed by `Enter` is swallowed, recent
directories are not listed, and neither the switch nor the opt-in single-column
layout exists. Several of those 24 passes are *vacuous* — they assert that no list
was drawn, and on v2.1.6 no list is ever drawn — which is why the baseline is
measured rather than scaled from an older number.

The suite also carries a **buffer-integrity** assertion — the prompt
line must equal what was typed, then the command that actually ran must print the
expected output — because a popup that silently swallows one keystroke per drawn
list still "passes" every look-at-the-screen check. The harness ships in the repo
(auto-skips without `tmux`):

```zsh
./tests/e2e-tmux.sh                              # advisory; asserts on the rendered screen
./tests/e2e-tmux.sh /tmp/zsc-v216               # A/B an older release
```

The method is written up in the `headless-pty-zle-verify` skill.

`tests/test-repaint.zsh` covers the part the tmux harness **structurally cannot
see**: the bytes zsh writes per keystroke. tmux undoes a newline-plus-cursor-up
pair, so its screen *and* its scrollback come out identical whether or not the
plugin emits a scroll-inducing redraw on every keypress. The test drives a real
`zsh -i` through `zsh/zpty` and reads the raw byte stream, asserting one
invariant: **one keystroke stays on one line** — no newline, no vertical cursor
move, no screen erase. Measured, one keystroke with a two-line prompt:

| build | bytes | scroll-inducing newline |
| --- | --- | --- |
| a redraw on every keystroke | 96 | yes — and 32 bytes even with the ghost *and* the popup switched off, where stock zsh writes 1 |
| this release | 33 | no — and 1 byte with both switched off, exactly stock zsh |

It fails on the old build and passes on this one, so a future "fix" that
reinstates the redraw is caught by CI rather than by a user. See CHANGELOG
`[v2.2.10]`.

## License

MIT — see [LICENSE](./LICENSE).
