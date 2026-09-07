# zsh-smart-complete

> A modern smart completion & suggestion layer for Zsh.
> Engineered as the frontend of a future independent shell.
>
> **v2.0.0 — General Availability.** Stable, production-ready.

## Status

| Channel | Status |
| ------- | ------ |
| Build & test (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| Release | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| Version | 2.0.0 (GA) |

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

## Architecture (v2.0.0)

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

> ⚠️ **This plugin replaces BOTH `zsh-autocomplete` and `zsh-autosuggestions`.**
> If you currently use either, remove them first (see below). Running all
> three together produces duplicate inline suggestions and a Tab key that
> fights itself.

#### Option A — One-key installer (recommended)

The bundled `install.sh` does everything in one pass: detects your OS
(macOS / Ubuntu / Debian / QNAP-Entware), **checks for Zsh and guides you
to install it if missing** (Homebrew / apt / opkg), installs Zsh · fzf ·
Zinit · Starship, clones this plugin, writes the recommended `.zshrc`
block,
**and automatically detects + offers to back up and remove conflicting
plugins** (zsh-autocomplete / zsh-autosuggestions), **and detects Oh My
Zsh / Powerlevel10k and lets you pick a config combo** (Zinit + Starship
recommended, or keep OMZ + p10k, or Zinit + p10k) — see below.

On Entware / QNAP / OpenWrt, `install.sh` auto-detects `opkg` and
**delegates to the dedicated `install-entware.sh`** (no `sudo`, no
`chsh`/`/etc/shells` — it switches your login shell via `~/.profile`
and prints QNAP GUI instructions instead).

Run it directly (downloads + executes):

```zsh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh)"
```

国内用户可改用镜像加速版——安装脚本本身的抓取、以及后续所有 GitHub 下载（Zinit / 本插件 / Starship / Atuin 内层二进制）全部走 `ghproxy.net`：

```zsh
SMART_INSTALL_GH_MIRROR=https://ghproxy.net/ bash -c "$(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh)"
```

> 镜像加速子系统的完整说明见下方「国内代理加速」一节。即便不加镜像前缀，安装器也会在开始时对多个候选镜像**自动测速并推荐最快的**，可交互选择，或用 `NONINTERACTIVE=1` 自动采用最快镜像。若 `ghproxy.net` 不可用，把上面两处 `https://ghproxy.net/` 换成 `https://kgithub.com/`、`https://gitclone.com/` 或 `https://ghproxy.com/` 等任意镜像前缀即可。

Or clone first and run locally — recommended so you can review the script:

```zsh
git clone https://github.com/imonior/zsh-smart-complete.git /tmp/zsc
/tmp/zsc/install.sh
```

Useful flags (can be combined):

```zsh
NONINTERACTIVE=1 ./install.sh   # CI / headless: yes for safe, no for destructive
SKIP_DEPS=1     ./install.sh    # skip external downloads (system pkgs only)
```

> The one-key installer **includes** the Zinit-based load method and the
> conflict cleanup — it is the superset of Options B and the manual removal
> steps below, so most users only need this one command.

#### Already using zsh-autocomplete / zsh-autosuggestions?

This plugin is a complete replacement for both. Remove them before loading
zsh-smart-complete:

- **Using the one-key installer** → it greps `~/.zshrc` for active loader
  lines and scans `~/.zinit/plugins` for the plugin directories, then
  prompts to move each to a `.bak.<timestamp>` backup and remove the original.
- **Using Oh My Zsh** → remove `zsh-autosuggestions` (and `zsh-autocomplete`
  if present) from your `plugins=()` array, then delete:

  ```zsh
  rm -rf ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions
  rm -rf ~/.oh-my-zsh/custom/plugins/zsh-autocomplete
  ```
- **Using Antidote / znap / manual** → delete the `source` / `zinit light` /
  `antidote` / `plug` line for those plugins from `~/.zshrc` and remove their
  directories (e.g. `~/.antidote/...`, `~/.../zsh-autosuggestions`).

After removing them, restart Zsh (`exec zsh`) before loading zsh-smart-complete.

#### Already using / not yet using Oh My Zsh / Powerlevel10k?

The one-key installer **always asks you to pick a config combo** (whether or not
OMZ/p10k are already installed). It detects an existing **Oh My Zsh**
(`~/.oh-my-zsh`, or a `source …/oh-my-zsh.sh` line in `~/.zshrc`) and/or
**Powerlevel10k** (`~/.p10k.zsh`, a `powerlevel10k` theme reference, or a
`~/powerlevel10k` directory), then offers three choices — the recommended one is
**Zinit + Starship**, with **Oh My Zsh + Powerlevel10k** and **Zinit +
Powerlevel10k** offered as alternatives:

1. **(推荐) Zinit + Starship** — when OMZ/p10k already exist they are commented out
   in `~/.zshrc` (`.bak` backup kept) and optionally removed; when they are **not**
   installed this is just a clean fresh install. A clean Zinit + Starship block is
   written either way.
2. **Oh My Zsh + Powerlevel10k** — the classic stack. If OMZ/p10k are not yet
   installed, the installer fetches them for you (OMZ via its official one-key
   script through the GitHub mirror, p10k cloned as an OMZ theme and
   `ZSH_THEME="powerlevel10k/powerlevel10k"` set); if they already exist they are
   kept and zsh-smart-complete is appended *after* OMZ.
3. **Remove OMZ, keep p10k → Zinit + Powerlevel10k** — OMZ is removed but p10k is
   kept (loaded via `zinit light romkatzen/powerlevel10k`).

The recommended path (1) is the cleanest and avoids duplicate completion / Tab-key
conflicts. In `NONINTERACTIVE=1` mode (or via `SMART_INSTALL_COMBO=zinit-starship`)
the installer always picks (1); `SMART_INSTALL_COMBO` also accepts `keep-omz` and
`zinit-p10k`.

#### Option B — Zinit (manual)

```zsh
zinit ice wait lucid
zinit light imonior/zsh-smart-complete
```

Requires Zsh's native `compinit` to be run in `.zshrc` (see Prerequisite above).

#### Option C — Manual clone

```zsh
git clone https://github.com/imonior/zsh-smart-complete.git ~/.zsh-smart-complete
```

Then add to `~/.zshrc` (after your own `compinit`):

```zsh
source ~/.zsh-smart-complete/zsh-smart-complete.plugin.zsh
```

#### QNAP / Entware (dedicated installer)

QNAP NAS (and other opkg-based systems like OpenWrt) run **Entware**, which
uses the `opkg` package manager, runs as `admin`/root with **no `sudo`**, and
has **no `/etc/shells` / `chsh`**. The generic `install.sh` therefore hands
off to a purpose-built `install-entware.sh` that:

- Installs **Zsh** via `opkg install zsh` (no `sudo`).
- Switches your login shell to zsh by appending a guarded `exec zsh` block to
  `~/.profile`, and prints the QNAP GUI path
  (Control Panel → Terminal → Default shell → zsh).
- Treats **fzf** and **Starship** as **optional** — they're skipped silently
  if your entware feed lacks them (the plugin core works without either).
- Installs **Zinit** + clones the plugin, runs the same conflict cleanup, and
  appends the loader block to `~/.zshrc`.

Run it (it is also auto-invoked by `install.sh` when `opkg` is detected):

```zsh
# from a local clone
git clone https://github.com/imonior/zsh-smart-complete.git /tmp/zsc
/tmp/zsc/install-entware.sh

# or download + run directly
curl -fsSL https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install-entware.sh -o install-entware.sh
bash install-entware.sh
```

Headless / CI flags (same as `install.sh`):

```zsh
NONINTERACTIVE=1 bash install-entware.sh   # yes for safe, no for destructive
SKIP_DEPS=1     bash install-entware.sh    # skip external downloads
```

> On QNAP, a new SSH login will auto-launch zsh via `~/.profile`. To reload
> the current session immediately run `exec /opt/bin/zsh` (or whichever path
> the installer reported).

#### 国内代理加速（GitHub 镜像自动选择）

`zsh-smart-complete` 本体以及 Zinit、`fzf`、`starship`、`atuin` **全部托管在 GitHub**。
安装器内置一套 GitHub 镜像加速子系统：**安装开始时会对多个候选镜像做测速，推荐最快的，
并允许你在交互中选择（推荐项 / 直连 / 手动输入自定义前缀）**。一旦选定，后续所有
`git clone`（Zinit、本插件、fzf 回退安装）和 raw 文件下载（模板、`starship`/`atuin`
安装脚本的外层抓取）都会自动走该镜像前缀，无需逐项配置。

支持的环境变量（可跳过交互、直接指定）：

```zsh
SMART_INSTALL_GH_MIRROR=direct   bash install.sh   # 强制直连（不使用加速）
SMART_INSTALL_GH_MIRROR=https://ghproxy.net/ \
                                bash install.sh   # 强制使用指定镜像前缀
```

一键镜像安装（无需先 clone，安装脚本本身也走镜像）：

```zsh
SMART_INSTALL_GH_MIRROR=https://ghproxy.net/ bash -c "$(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh)"
```

交互行为：

- **测速**：安装开始即对全部候选镜像拉取本项目一个极小的 raw 文件并计时。
- **列表选择**：所有候选（含直连）连同耗时一并列出并编号，最快且可用的标记为
  `(推荐)`；此外单列一个「手动输入自定义镜像前缀 URL」选项。
- **输入序号 + 回车**：直接输入编号即可选中对应镜像；留空回车则采用推荐项。
  `NONINTERACTIVE=1`（CI/无头）时自动采用最快镜像，全部不可用时回退直连。
- **手动输入**：选择末尾的「手动输入」项后，粘贴任意镜像前缀 URL
  （如 `https://ghproxy.com/`、`https://kgithub.com/`、`https://gitclone.com/`）。

> **关于 `starship` / `atuin` 的二进制下载**：它们的一键脚本会从 GitHub Releases
> 自取二进制。安装器在运行这类脚本时，会临时把一个**重写 GitHub URL 的 `curl`/`wget`
> shim** 放到 `PATH` 最前面，因此**内层二进制下载同样走所选镜像加速**（前提是脚本用
> `curl`/`wget` 下载；少数脚本若使用自带 HTTP 客户端则不受控）。仍建议优先用系统包管理器
> （apt / brew / opkg）安装这些二进制；或运行安装器前配置 Git 全局镜像：
> `git config --global url."https://gitclone.com/".insteadOf https://`。

#### 可选组件：fzf / Starship / Atuin 官方安装命令

三者均开源并托管于 GitHub，可单独安装（安装器也会按上述镜像加速去拉取）：

```zsh
# fzf — 模糊查找器（插件核心不依赖，但装上体验更好）
git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf && ~/.fzf/install

# starship — 跨平台提示符
curl -sS https://starship.rs/install.sh | sh

# atuin — 加密同步的 shell 历史（Ctrl-R 升级版）
curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh
```

> 安装器在 `~/.zshrc` 的集成块里已包含 `atuin init zsh` 的 `command -v` 守卫——
> 装好 atuin 后重开终端即自动启用，无需再手动改配置。

### Default keys

| Key     | Action                    |
| ------- | ------------------------- |
| `→`     | Accept inline suggestion  |
| `Tab`   | Native completion         |
| `↑`/`↓` | History cycle (viins)     |
| `Ctrl+G`| Disable/enable plugin     |

## Configuration

All knobs below are plain Zsh variables. **Edit `~/.zshrc`** and put the
`export`/`typeset` lines **before** the line that loads the plugin:

```zsh
# If you used Zinit:
zinit light imonior/zsh-smart-complete
# If you used the Manual clone:
source ~/.zsh-smart-complete/zsh-smart-complete.plugin.zsh
```

If you ran the one-key installer, the loader is inside the
`# zsh-smart-complete integration` block it appended to your `~/.zshrc` —
add your overrides just above that block.

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
v1.0.0  GA — stable public API, CI/CD, automated releases
   │
v2.0.0  Engine & installer overhaul — O(bucket) prefix index, de-subShell scoring, real-time incremental indexing, zsh detection, OMZ/p10k combo selector, Entware installer  ← you are here
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
