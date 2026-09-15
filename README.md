# zsh-smart-complete

> A modern smart completion & suggestion layer for Zsh.
> Engineered as the frontend of a future independent shell.
>
> **v2.2.0** — Latest release: native type-to-popup candidate menu (the `zsh-autocomplete` half), `Alt+→` accepts one word, right-arrow SS3 fix.

[English](./README.md) · [简体中文](./README.zh-CN.md) · [繁體中文](./README.zh-TW.md) · [日本語](./README.ja.md) · [한국어](./README.ko.md)

## Status

| Channel | Status |
| ------- | ------ |
| Build & test (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| Release | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| Version | 2.2.0 |

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
: ${SMART_MENU_MAX_PREFIX:=64}
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
```

## Runtime commands

```zsh
smart-status      # print current state + config
smart-disable     # disable the plugin
smart-enable      # re-enable
smart-reindex     # force a history index rebuild
smart-menu on     # turn the type-to-popup list on
smart-menu off    # turn it off (inline ghost text unaffected)
smart-menu status # show menu config + last listing result
```

## Uninstall

```zsh
rm -rf ~/.zsh-smart-complete
```

## Changelog

See [CHANGELOG](./CHANGELOG.md) for the full history.

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
```

**Test summary (v2.2.0):** 8 test files, 359 assertions, all passing, 0 failures.

Key behaviours are additionally verified end-to-end against a real `zsh -i` in a
tmux pane, asserting on the rendered screen (13/13 green). The same assertions
score **6/13 on v2.1.6** — the type-to-popup menu did not exist and the SS3 right
arrow was dead. The harness ships in the repo (auto-skips without `tmux`):

```zsh
./tests/e2e-tmux.sh                              # 13 assertions
./tests/e2e-tmux.sh /tmp/zsc-v216               # A/B an older release
```

The method is written up in the `headless-pty-zle-verify` skill.

## License

MIT — see [LICENSE](./LICENSE).
