# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this
project adheres to [Semantic Versioning](https://semver.org/).

## [v2.2.0] - 2026-09-15

The release that finally delivers the *whole* reason this plugin exists: the two
halves of `zsh-autocomplete` + `zsh-autosuggestions`, natively, in one plugin.

### Added
- **Type-to-popup candidate menu** (`lib/engine/menu.zsh`): the candidate list is
  computed and drawn on every buffer edit, so completions appear while you type —
  no `Tab` required. Implemented on top of the user's own compsys via a private
  completion widget (`zle -C ... list-choices`) whose completer reads
  `compstate[nmatches]` and decides whether the list is drawn; `compinit` is never
  touched. Master switch `SMART_MENU`, runtime `smart-menu on|off|status`.
- **Inline ghost text and the candidate list coexist.** The listing redraw and
  `POSTDISPLAY` fight over the same screen area, so the order is fixed: render the
  ghost first, then run the listing, and never redraw afterwards. A single
  candidate (`SMART_MENU_MIN_MATCHES`) drops the list and lets the ghost speak.
- **Adaptive throttle** (`SMART_MENU_SLOW_MS` / `SMART_MENU_COOLDOWN_KEYS`, off by
  default): a listing at or above the threshold buys a cool-down, for the rare
  completion that is *persistently* expensive. It is off because the only spike
  measured in practice is a one-off ~180ms when a completion subsystem loads, and
  throttling that costs the popup on the first `git <TAB>` of a session while
  saving 180ms once.
- **`SMART_MENU_DEBUG=/path/to/log`** appends one line per tick decision: whether
  the gate refused, whether the cool-down swallowed the edit, the match count and
  the measured cost. "The popup didn't appear" is otherwise indistinguishable from
  "one match, so the ghost took over".
- **`Alt+→` accepts one word** of the inline suggestion (then re-suggests the
  rest). Falls back to the stock `forward-word` when there is nothing to accept.

### Fixed
- **CRITICAL - right arrow did nothing on a fresh session**: only `ESC [ C` (CSI)
  was bound, but `TERM=xterm-256color` reports `kcuf1` as `ESC O C`, the
  *application cursor keys* form, and ZLE switches the terminal into that mode. The
  key therefore hit zsh's stock `forward-char` and the suggestion was never
  accepted, while the grey text was clearly visible — the classic "ghost shows but
  the arrow is dead" report. All arrow encodings are now bound, with the sequence
  list built from `terminfo` plus CSI/SS3 fallbacks.
- **CRITICAL - `Alt+→` dead on the same terminals**: `Alt` is literally "send `ESC`,
  then the arrow", so it inherits the multi-encoding problem. Only `ESC [ 1 ; 3 C`
  (xterm) and `ESC ESC [ C` were bound; a terminal in application-cursor mode sends
  `ESC ESC O C`, which was unbound and dropped a literal `^[` into the buffer. The
  Alt forms are now *derived* by prefixing `ESC` onto every plain-arrow encoding, so
  they cannot drift apart again.
- **Binding capture mis-parsed raw byte sequences**: `_smart_evt_binding`
  (`lib/event/zle.zsh`) and `_smart_current_binding` (`lib/engine/native.zsh`)
  stripped the key by matching the queried sequence textually, but `bindkey` always
  echoes the key in `^X` caret notation — so for a raw-byte sequence (e.g. the
  terminfo `kcuf1`) the match failed and the *key text* was stored as the widget
  name. Saved originals were poisoned and the key was never restored on unbind. Both
  parsers now take the last field of the `bindkey` output.
- **`local` inside a loop leaked to stdout** (`lib/event/zle.zsh`): zsh 5.9 prints
  `var='<old value>'` whenever a `local` declaration is executed a second time, which
  is what happens to a `local` written inside a loop that iterates more than once.
  That output lands straight on the command line in a ZLE widget path. All loop
  variables are now declared once at the top of the function; `tests/test-zle.zsh`
  asserts the bind/unbind cycle stays silent.
- **`zmodload -F` feature prefixes**: `EPOCHREALTIME` and `terminfo` are
  *parameters*, so they must be requested as `p:EPOCHREALTIME` / `p:terminfo`. The
  rejected `b:` requests left both undefined — silently disabling the throttle and
  the terminfo-derived arrow sequences. Regression tests added.
- **Quoted associative-array subscripts**: `assoc["km|seq"]=x` stores the quotes as
  part of the key, so the entry is unreachable via `assoc[km|seq]`. Keys are now
  built in a variable and indexed with an unquoted subscript (the same rule
  `lib/state.zsh` already followed).
- **Installer**: explains *why* `zsh-autocomplete` / `zsh-autosuggestions` are
  removed (both behaviours are native now), instead of silently deleting them.

## [v2.1.6] - 2026-09-15

### Fixed
- **CRITICAL - printable ASCII input swallowed**: `_smart_evt_binding` captured the
  pseudo-widget `undefined-key` from the `bindkey -R "^@-^_"` range query and
  dispatched printable keys to it, so `zle undefined-key` (a no-op) ate every ASCII
  keystroke. CJK/UTF-8 (bytes >= 0x80, outside the rebound range) still inserted via
  the real `self-insert` — hence "Chinese works, English does not". The capture now
  normalises `undefined-key` to unbound so `self-insert` is used;
  `_smart_evt_dispatch` also guards against it; `_smart_current_binding`
  (native.zsh) got the same hardening. Regression test added in `tests/test-zle.zsh`.
- **Key-capture hardening**: the self-insert original is now hard-coded instead of
  range-probed (a range query reports `undefined-key` before our bind and our own
  wrapper after it — neither is a usable original). Capture is guarded by a
  dedicated `_SMART_EVT_CAPTURED` flag rather than the content of one `ORIG_*`
  variable, so a stale or hand-set `_SMART_EVT_ORIG_SELF_*` can no longer skip the
  whole capture (which silently also dropped the native Tab bindings and every other
  original). A capture probe additionally refuses to record any `_smart_*` /
  `smart-*` widget, so a re-capture can never dispatch back into our own wrapper.
- **Installer - managed block markers were never written**: `build_zsc_integration`
  used `print -r --` (a zsh builtin) inside a bash script, so the call failed
  silently and the `# >>> zsh-smart-complete integration (managed) >>>` / `# <<< ...
  <<<` marker lines were dropped. Without the BEGIN marker `_upsert_zsc_block` could
  never match, so every re-install appended a duplicate block instead of replacing in
  place. Now uses `printf '%s\n'`.

### Added
- **Optional `zsh-vi-mode` (opt-in, default NO)**: vi keybindings are genuinely
  useful, but the plugin owns the whole keymap and re-initialises ZLE on every
  line-init, which is the classic way to break other plugins' bindings — so it is
  never installed implicitly. When opted in, the installer clones it and writes a
  block that loads it *before* zsh-smart-complete and re-applies our widgets via
  `zvm_after_init` / `zvm_after_lazy_keybindings`.
- **Installer installs fast-syntax-highlighting** in the flow
  (`_ensure_zinit_plugin zdharma-continuum/fast-syntax-highlighting`) on both the
  full-combo and plugin paths, so it no longer depends on Zinit auto-cloning at first
  shell start.

### Changed
- **Installer .zshrc strategy**: the complete recommended `.zshrc` template is only
  recommended when the full stack was (re)installed this run (Phase 0/5 combo); a
  plugin-only install now only manages the marker-delimited `zsh-smart-complete`
  block (idempotent upsert, never overwrites the whole file).

## [v2.1.5] - 2026-09-15

### Fixed
- **Installer - p10k/OMZ removers**: `_remove_p10k` / `_remove_omz` now also delete
  the Zinit-cloned plugin dir under `$ZINIT_PLUGINS_DIR` (e.g.
  `romkatzen---powerlevel10k`, `OMZ::ohmyzsh---ohmyzsh`), so picking a non-p10k/OMZ
  combo fully clears stale remnants that previously re-loaded on next start. `.bak.*`
  artifacts are deleted directly to avoid cascading backups.
- **Installer - `.zwc` bytecode**: the plugin update path (`git reset --hard`) now
  also removes Zinit-compiled `*.zwc` caches, so engine fixes actually take effect
  after an update (previously stale compiled code loaded).
- **Engine - global leak**: `cmd_cwd` / `cmd_host` / `cmd_exit` in
  `lib/engine/suggest.zsh` are now declared `local` (were leaking as globals on every
  keystroke).
- **Engine - history cap**: `_SMART_CMDS` is now capped to
  `SMART_SUGGEST_HISTORY_LIMIT` (default 20000); when `SMART_HISTORY_REBUILD_EVERY=0`
  disables the periodic rebuild, the oldest entry is dropped and its bucket/assoc
  slots stay in sync.

## [v2.1.4] - 2026-09-12

### Fixed
- fzf install was silently skipped (no interaction); install progress shown twice
  (Phase 0/5 then Phase 1-4). Added a `RAN_COMBO` guard and made fzf prompts
  interactive.

## [v2.1.3] - 2026-09-11

### Fixed
- `read: -: invalid option` crash on every y/N prompt — `IFS=$'\n\t'` broke
  `read $_args`; switched to `read "$@"`.

## [v2.1.2] - 2026-09-10

### Fixed
- Installer prompts now block until the user confirms each step; conflict-plugin
  `.bak.*` cascade fixed (primary dir backed up once); stale plugin now actually
  updated via `git fetch --depth 1` + `git reset --hard`.

## [v2.1.1] - 2026-09-09

### Added
- **zsh reinstall prompt**: When zsh is already installed, prompt user to
  reinstall/upgrade via brew (macOS) or apt (Debian/Ubuntu).
- **fast-syntax-highlighting**: Loaded via `zinit light
  zdharma-continuum/fast-syntax-highlighting` in `.zshrc` template (Zinit
  auto-clones at startup); not managed by install.sh directly.
- **i18n messages**: Added `prompt.zsh_reinstall` in zh-CN, zh-TW, ja, ko, en.

### Changed
- **Phase 0**: Full combo install now includes zsh reinstall logic;
  fast-syntax-highlighting loaded by Zinit via `.zshrc` template.
- **Phase 1-3**: Restored `SKIP_DEPS` guards on starship/atuin/zinit prompts.

### Fixed
- zsh reinstall prompt uses correct brew/apt fallback logic.

## [v2.1.0] - 2026-09-08

### Added
- **Phase 0/5**: Full recommended combo install (zsh + fzf + starship + atuin + zinit
  + zsh-smart-complete).
- **Interactive backup cleanup**: Prompt user to clean conflict plugin residues
  (`.cache/p10k-*`, `.cache/zsh*`, `.local/state/zsh-autocomplete` etc.).
- **fzf auto-install**: Clone from GitHub if not available via package manager.

### Changed
- Installer now runs Phase 0 first when `SKIP_DEPS!=1` and `NONINTERACTIVE!=1`;
  Phase 1-3 remain as fallback when Phase 0 is skipped.

## [v2.0.6] - 2026-08-26

### Fixed
- Release workflow: stage files before tar/zip to avoid 'file changed' race
  condition.

## [v2.0.5] - 2026-08-26

### Fixed
- Bad substitution in `mirror.chosen` message.
- Cleanup old `.bak.*` residuals.

## [v2.0.3] - 2026-08-26

### Fixed
- i18n: Translate all remaining Chinese status messages.
- SSH input issue fix.

## [v2.0.2] - 2026-08-26

### Fixed
- i18n: Mirror selection menu now fully internationalized.

## [v2.0.1] - 2026-08-26

### Fixed
- Resolve 3 installer issues: i18n combo menu, OMZ/p10k default yes,
  starship.toml escape.

## [v2.0.0] - 2026-08-25

### Added
- Engine & installer overhaul.
- O(bucket) prefix index.
- de-subShell scoring.
- Real-time incremental indexing.
- Zsh detection.
- OMZ/p10k combo selector.
- Entware installer.
- Stop per-keystroke stdout leak that garbled the ZLE line editor.

## Earlier releases

```
v0.1.0  ZLE frontend, history index, suggestion engine
   │
v0.1.3  Deterministic ranking (decay + frequency + CWD boost)
   │
v0.2.0  Atuin SQLite backend (host / exit / CWD-aware ranking)
   │
v1.0.0  GA — stable public API, CI/CD, automated releases
   │
v2.0.0  Engine & installer overhaul — O(bucket) prefix index, de-subShell
        scoring, real-time incremental indexing, zsh detection, OMZ/p10k combo
        selector, Entware installer
   │
v2.1.0  Phase 0 full combo install (zsh + fzf + starship + atuin + zinit +
        zsh-smart-complete), interactive backup cleanup
   │
v2.1.6  fix printable-ASCII input (undefined-key), capture hardening,
        fast-syntax-highlighting, combo-aware .zshrc, opt-in zsh-vi-mode
   │
v0.5.x  smart-shell-engine (Rust / Go) over IPC  (future, opt-in)
   │
v2.0    Smart Shell — full standalone shell  (future)
```
