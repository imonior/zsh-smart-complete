# zsh-smart-complete

> A modern smart completion & suggestion layer for Zsh.
> Engineered as the frontend of a future independent shell.
>
> **v2.2.9** — The inline suggestion is now clearly coloured, and the candidate list waits for two keystrokes. A single letter no longer paints a full history list (the gate now counts the last `/`-segment, so `/etc/l` is one character); the grey ghost uses `auto`, which resolves to a dimmer blue-grey `fg=110` on 256-colour terminals. The installer also repairs Starship configs that reverted to the default prompt (missing `format` line) — re-running it now fixes them, and the bundled layout is the two-line `username › directory / :>` prompt.

[English](./README.md) · [简体中文](./README.zh-CN.md) · [繁體中文](./README.zh-TW.md) · [日本語](./README.ja.md) · [한국어](./README.ko.md)

## Status

| Channel | Status |
| ------- | ------ |
| Build & test (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| Release | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| Version | 2.2.9 |

## Why

Replaces both `zsh-autocomplete` and `zsh-autosuggestions` in a single plugin with a clean modular architecture, designed to evolve into a standalone shell.

- **Two halves, one engine (v2.2.0)** — while you type, the candidate list pops up *immediately* (the `zsh-autocomplete` behaviour) while the inline grey suggestion stays; `→` accepts it all, `Alt+→` accepts one word (the `zsh-autosuggestions` behaviour). One plugin, one keymap, two channels — the real fix for "the two plugins conflict".
- **Zero external dependencies** — the core plugin is self-contained; Atuin is optional.
- **Every arrow-key encoding is bound** — both `ESC [ C` and `ESC O C` (application cursor-keys mode, what `TERM=xterm-256color` actually sends) are bound, so you never get "grey text shows but the arrow does nothing".
- **Syntax-highlighting friendly** — uses the `#zsh-smart-complete:suggestion` tag; does not override other highlighters.

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

The installer auto-detects your public-IP region and reports it. The region decides **which candidates are worth showing**: mainland China / not detected show every candidate and speed-test every candidate including direct (whether direct is really faster should be measured, not guessed from geography); **outside mainland China hides every preset mirror** and keeps only direct — those ghproxy / gitclone channels are mainland-only and are often slower than direct out there. Even outside mainland China, though, **direct is still speed-tested**, and both manual entries are always available: a **mirror source** (rewrites GitHub URLs) or a **full proxy** (exported as `HTTP_PROXY`/`HTTPS_PROXY` so curl/git/wget route everything through it, e.g. `http://127.0.0.1:7890`). Preset mirrors are labelled *China mainland only*. The snippets below are only needed for non-interactive installs.

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
: ${SMART_MENU_MIN_MATCHES:=2}        # below this many candidates, no list (a single one stays ghost text)
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
  recent directories are generated. Everything else (git subcommands, ssh hosts,
  `--options`, `sudo …`) produces nothing here and falls through to the native
  grid, so **the popup changes shape while you type** — easily mistaken for a
  second list appearing.
- A candidate wider than the terminal is clipped to one line (no ellipsis).

The mechanism is arithmetic: every *display* string is padded — or clipped — to
exactly `COLUMNS` wide, so exactly one column fits. The typed word is escaped
before it becomes a glob, so a `[` in a filename cannot break the popup (a
leading `~/` stays unescaped, so `~/…` candidates keep working).

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

## Uninstall

```zsh
rm -rf ~/.zsh-smart-complete
```

## Changelog

See [CHANGELOG](./CHANGELOG.md) for the full history. The GitHub Release notes are extracted from these multi-language CHANGELOG files (en / zh-CN / zh-TW / ja / ko).

## Testing

```zsh
zsh tests/test-config.zsh
zsh tests/test-history.zsh
zsh tests/test-suggest.zsh
zsh tests/test-ranking.zsh
zsh tests/test-atuin.zsh
zsh tests/test-zle.zsh
zsh tests/test-menu.zsh
zsh tests/test-integration.zsh
zsh tests/test-recent.zsh
bash tests/test-installer-options.sh
```

**Test summary (v2.2.9):** 10 test files, 757 assertions, all passing, 0 failures.
The installer also now **scans other startup files** (`.zprofile`, `.zshenv`, `conf.d/*.zsh`, `.zshrc.d/*`, `/etc/zsh/zshrc`) for left-over loaders of `zsh-autocomplete` / `zsh-autosuggestions` after cleaning `~/.zshrc`, and **warns** (with exact `file:line`) if it finds any — it never edits those files. See CHANGELOG `[v2.2.5]`.


Key behaviours are additionally verified end-to-end against a real `zsh -i` in a
tmux pane, asserting on the rendered screen (49/49 green). The same assertions
score **23/49 on v2.1.6** (one of the 49 is not even reached there: its section
stops after a failure), where the type-to-popup does not exist, the `SS3` and
`Alt+→` encodings are dead, `Tab` followed by `Enter` is swallowed, recent
directories are not listed, and neither the switch nor the opt-in single-column
layout exists. Several of those 23 passes are *vacuous* — they assert that no list
was drawn, and on v2.1.6 no list is ever drawn — which is why the baseline is
measured rather than scaled from an older number.

The suite also carries a **buffer-integrity** assertion — the prompt
line must equal what was typed, then the command that actually ran must print the
expected output — because a popup that silently swallows one keystroke per drawn
list still "passes" every look-at-the-screen check. The harness ships in the repo
(auto-skips without `tmux`):

```zsh
./tests/e2e-tmux.sh                              # 49 assertions
./tests/e2e-tmux.sh /tmp/zsc-v216               # A/B an older release
```

The method is written up in the `headless-pty-zle-verify` skill.

## License

MIT — see [LICENSE](./LICENSE).
