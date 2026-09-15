# zsh-smart-complete

> A modern smart completion & suggestion layer for Zsh.
> Engineered as the frontend of a future independent shell.
>
> **v2.2.2** — Latest release: recent-directory candidates while completing `cd`; a `Tab` followed by `Enter` now actually runs the line; fuzzy matching documented (it is zsh's, not ours).

[English](./README.md) · [简体中文](./README.zh-CN.md) · [繁體中文](./README.zh-TW.md) · [日本語](./README.ja.md) · [한국어](./README.ko.md)

## Status

| Channel | Status |
| ------- | ------ |
| Build & test (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| Release | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| Version | 2.2.2 |

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
bash <(curl -fsSL https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh)
```

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

```zsh
SMART_INSTALL_GH_MIRROR=https://ghproxy.net/ bash -c "$(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh)"
```

## Configuration

Set these variables **before** the plugin loads:

```zsh
# Master switch
: ${SMART_ENABLED:=true}
# Engines
: ${SMART_SUGGEST:=true}
: ${SMART_COMPLETE:=true}
: ${SMART_SUGGEST_STRATEGY:=history}  # history | history,completion (completion also draws on the completion system)
# History backend: zsh | atuin | smart-engine (future)
: ${SMART_HISTORY_BACKEND:=zsh}
# UI
: ${SMART_INLINE:=true}
: ${SMART_SUGGEST_COLOR:=fg=8}

# Type-to-popup candidate list (the zsh-autocomplete half)
: ${SMART_MENU:=true}
: ${SMART_MENU_MIN_PREFIX_CMD:=2}     # min chars in the COMMAND word before listing
: ${SMART_MENU_MIN_PREFIX:=1}         # min chars in an ARGUMENT word (0 = also right after a space)
: ${SMART_MENU_MIN_MATCHES:=2}        # below this many candidates, no list (a single one stays ghost text)
: ${SMART_MENU_MAX_MATCHES:=100}       # more candidates than this -> no list (keeps huge dirs, and zsh's "see all N possibilities" prompt, away)
: ${SMART_MENU_MAX_PREFIX:=64}
: ${SMART_MENU_HISTORY_KEYS:=false}  # true = up/down prefix-search history while the line is non-empty
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

## Runtime commands

```zsh
smart-status      # print current state + config
smart-disable     # disable the plugin
smart-enable      # re-enable
smart-reindex     # force a history index rebuild
smart-menu on     # turn the type-to-popup list on
smart-menu off    # turn it off (inline ghost text unaffected)
smart-menu status # show menu config + last listing result
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
```

**Test summary (v2.2.2):** 9 test files, 438 assertions, all passing, 0 failures.

Key behaviours are additionally verified end-to-end against a real `zsh -i` in a
tmux pane, asserting on the rendered screen (29/29 green). The same assertions
score **17/29 on v2.1.6** — the type-to-popup menu did not exist and the SS3 right
arrow was dead. This version adds a **buffer-integrity** assertion — the prompt
line must equal what was typed, then the command that actually ran must print the
expected output — because a popup that silently swallows one keystroke per drawn
list still "passes" every look-at-the-screen check. The harness ships in the repo
(auto-skips without `tmux`):

```zsh
./tests/e2e-tmux.sh                              # 29 assertions
./tests/e2e-tmux.sh /tmp/zsc-v216               # A/B an older release
```

The method is written up in the `headless-pty-zle-verify` skill.

## License

MIT — see [LICENSE](./LICENSE).
