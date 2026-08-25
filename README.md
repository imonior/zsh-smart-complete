# zsh-smart-complete

> A modern smart completion & suggestion layer for Zsh.
> Engineered as the frontend of a future independent shell.
>
> **v1.0.0 — General Availability.** Stable, production-ready.

## Status

| Channel | Status |
| ------- | ------ |
| Build & test (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| Release | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| Version | 1.0.0 (GA) |

## Why

Replaces **both** `zsh-autocomplete` and `zsh-autosuggestions` with a clean,
modular architecture designed for evolution into a standalone shell:

- **No `compinit` hijack** — uses whatever completion the user already has.
- **No `line-pre-redraw` polling** — suggestions are computed only when the
  buffer actually changes (self-insert, delete, kill-word…).
- **In-memory history index** — built from `fc` once (and refreshed on
  demand), instead of scanning `$HISTFILE` or `${history}` every keystroke.
- **Unified state, event and display layers** — every upper layer maps
  cleanly to a future Rust/Go engine and, eventually, the native Smart Shell.
- **Optional Atuin backend** (v0.2.0+) — reuse an existing Atuin SQLite
  history with CWD / host / exit-aware ranking, with silent fallback to zsh.
- **Deterministic ranking** (v0.1.3+) — exponential time-decay + frequency +
  CWD boost, replicated 1:1 for the future Rust engine.

## Architecture (v1.0.0)

```
                 zsh-smart-complete.plugin.zsh
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
     config                state                  event/zle
        │                     │                     │
        └─────────────────────┼─────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
        engine/suggest                  engine/native
              │                               │
       history/history               (user's compinit)
              │
     zsh fc   │   atuin (opt)   │   smart-engine (future)
              └─────────────────┴───────────────────┘
                              │
                        display/
                    region_highlight
```

Modules:

| Module | Responsibility |
| ------ | ------------- |
| `lib/config.zsh`  | Feature flags, defaults, backend selection |
| `lib/state.zsh`   | Central `_SMART_STATE` associative array |
| `lib/history/history.zsh` | In-memory history index (freq + recency) |
| `lib/engine/suggest.zsh`  | Suggestion engine (prefix · recency · freq) |
| `lib/engine/native.zsh`   | Native completion bridge (uses user compinit) |
| `lib/display/display.zsh` | Inline suggestion rendering via `region_highlight` |
| `lib/event/zle.zsh`       | ZLE widgets + keymap bindings (emacs + viins) |

## Quick start

### Prerequisite

Let **Zsh itself** own `compinit` in your `.zshrc`:

```zsh
export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=1000000
export SAVEHIST=1000000
setopt appendhistory sharehistory histignorealldups

autoload -Uz compinit
compinit
```

### Install

#### Zinit (recommended)

```zsh
zinit ice wait lucid
zinit light imonior/zsh-smart-complete
```

#### Manual

```zsh
git clone https://github.com/imonior/zsh-smart-complete.git ~/.zsh-smart-complete
# Then in .zshrc:
source ~/.zsh-smart-complete/zsh-smart-complete.plugin.zsh
```

### Default keys

| Key     | Action                    |
| ------- | ------------------------- |
| `→`     | Accept inline suggestion  |
| `Tab`   | Native completion         |
| `↑`/`↓` | History cycle (viins)     |
| `Ctrl+G`| Disable/enable plugin     |

## Configuration

Set these **before** sourcing the plugin:

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
: ${SMART_SUGGEST_MAX:=1}
: ${SMART_SUGGEST_HISTORY_LIMIT:=20000}
: ${SMART_SUGGEST_COLOR:=fg=8}           # dim grey

# Rebuild index after N new commands (0 = never auto-rebuild)
: ${SMART_HISTORY_REBUILD_EVERY:=500}
```

### Ranking (v0.1.3+)

```zsh
# Exponential time-decay: higher alpha = faster recency decay.
: ${SMART_RANKING_DECAY_ALPHA:=10}     # default 10
# CWD boost (milli-units, 1000 = 1.0x): last-run-in-this-dir multiplier.
: ${SMART_RANKING_CWD_BOOST:=1500}     # default 1.5x
```

### Atuin backend (v0.2.0+)

Only takes effect when `SMART_HISTORY_BACKEND=atuin`. Falls back to zsh
silently if `sqlite3` is missing or the DB file does not exist.

```zsh
: ${SMART_ATUIN_DB_PATH:="${HOME}/.local/share/atuin/history.db"}
: ${SMART_ATUIN_HOST_BOOST:=1300}      # same-host multiplier (1.3x)
: ${SMART_ATUIN_FAILED_PENALTY:=500}  # failed-exit multiplier (0.5x)
: ${SMART_ATUIN_SUCCESS_ONLY:=false}   # drop failed-exit rows entirely
```

## Runtime commands

```zsh
smart-status      # Print current state + config
smart-disable     # Remove widgets + stop computing suggestions
smart-enable      # Re-enable after disable
smart-reindex     # Force a history index rebuild
```

## Uninstall

Remove the `source` / `zinit light` line from `.zshrc`, then:

```zsh
rm -rf ~/.zsh-smart-complete
```

## Roadmap

```
v0.1.0  ZLE frontend, history index, suggestion engine
   │
v0.1.3  Deterministic ranking (decay + frequency + CWD boost)
   │
v0.2.0  Atuin SQLite backend (host / exit / CWD-aware ranking)
   │
v1.0.0  GA — stable public API, CI/CD, automated releases  ← you are here
   │
   ▼
v0.5.x  smart-shell-engine (Rust / Go) over IPC  (future, opt-in)
   │
   ▼
v2.0    Smart Shell — full standalone shell  (future)
```

## Testing

The full suite lives under [`tests/`](./tests) and is run by CI on every push
and pull request (Ubuntu + macOS). Each file is self-contained and exits
non-zero on failure:

```zsh
zsh tests/test-config.zsh
zsh tests/test-history.zsh
zsh tests/test-suggest.zsh
zsh tests/test-ranking.zsh
zsh tests/test-atuin.zsh      # auto-SKIPs if sqlite3 is absent
zsh tests/test-zle.zsh
zsh tests/test-integration.zsh
```

## License

MIT — see [LICENSE](./LICENSE).
