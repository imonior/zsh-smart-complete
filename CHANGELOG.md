# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this
project adheres to [Semantic Versioning](https://semver.org/).

## [v2.2.5] - 2026-09-19

### Added
- **Conflict-loader advisory scan in other startup files (read-only).** The installer's conflict cleanup only edits `~/.zshrc` — by design, so it never touches config the user manages elsewhere. But `zsh-autocomplete` / `zsh-autosuggestions` loaders are sometimes placed in `.zprofile`, `.zshenv`, `conf.d/*.zsh`, `.zshrc.d/*` or `/etc/zsh/zshrc`. A loader that survives there keeps the plugin loading on every `exec zsh` and re-triggers the duplicate-suggestion / Tab-conflict symptom. After cleanup, the installer now **scans** those files and **warns** the user with the exact `file:line` so they can clean it manually. It never edits those files.

- **Region detection now decides which candidates are visible: outside mainland China the presets are hidden, but direct is still measured.** The public-IP geo-lookup has three results: **mainland China**, **outside mainland China**, and **not detected**. Mainland China / not detected: every candidate is shown and every candidate is speed-tested — **including direct**, because whether direct is actually faster should be measured rather than guessed from geography — and both manual entries stay available; an unknown region hides nothing either, so the choice stays with the user. **Outside mainland China: every preset mirror is hidden** (the ghproxy family and gitclone.com are mainland-only channels — there they can only mislead or be slower), leaving just direct — yet direct is **still speed-tested**, and both manual entries (mirror source, full proxy) remain. Menu numbers are compacted over the visible candidates, so there is no dead option that looks like "nothing happened". This also **removed `kgithub.com`**, a domain-swap mirror that cannot serve reliably long-term.
- **Two kinds of manual input: a mirror source, or a full proxy.** These are genuinely different mechanisms, so both are now offered. A **mirror source** rewrites GitHub URLs (prefix or domain swap). A **full proxy** — the kind you can set as a system proxy, e.g. `http://127.0.0.1:7890` or `socks5://127.0.0.1:1080` — is exported as `HTTP_PROXY`/`HTTPS_PROXY` so curl, git and wget route *every* request through it (URLs are left untouched). The proxy is reachability-tested before it is accepted, and can be set non-interactively with `SMART_INSTALL_PROXY`.
- **Preset mirrors are annotated "China mainland only".** ghproxy.net / ghproxy.com / mirror.ghproxy.com / gitclone.com exist to serve mainland-China networks, so they are labelled as such — otherwise a user outside mainland China can easily pick a channel that is slower for them than a direct connection.

### Fixed
- **Conflict detection no longer re-reports stale backups.** The zinit directory scan matches by substring, so a `zsh-autocomplete.bak.<timestamp>` backup left by a previous run was reported again as a "conflict plugin dir" even when no active plugin remained — and accepting the prompt then deleted that backup. Backup directories are now skipped (they are not active plugins), so only real plugin directories are reported.
- **The advisory scan no longer flags `fzf-tab`.** `fzf-tab` is a supported alternative list-drawer (`SMART_MENU_LISTER=fzf-tab`), so calling it a conflict contradicted the documented integration. Only `zsh-autocomplete` / `zsh-autosuggestions` — pure duplicates of what zsh-smart-complete already provides — are reported now.

## [v2.2.4] - 2026-09-16

### Added
- **`SMART_MENU_LISTER=builtin|fzf-tab` — the explicit 2-choose-1.** Two
  completion listers are both entitled to draw, so two popups on screen is not a
  bug either of them can fix: one has to stop. That choice is now a setting
  instead of an inference.

  ```zsh
  smart-lister                   # who owns the list right now?
  smart-lister fzf-tab           # we draw nothing; the external picker owns it
  smart-lister builtin           # take it back
  ```

  Handing it over stops only the **list**: the inline grey suggestion keeps
  working and `SMART_MENU` is untouched, so `smart-lister builtin` is a complete
  undo. `builtin`, `smart`, `internal`, `native`, `built-in`, `on`, `yes`, `true`
  and `1` all mean this plugin; `fzf-tab`, `fzf_tab`, `fzf`, `ftb`, `external`,
  `none`, `off`, `no`, `false` and `0` all mean hand it over (`off` means "our
  lister off", not "no list at all" — that is `SMART_MENU=false`). An
  unrecognised argument is **reported and returns non-zero**, instead of quietly
  printing the status block — which is how a typo used to pass for a successful
  switch. This setting does *not* install fzf-tab; the installer's fzf-tab
  question does that, and it writes the matching `SMART_MENU_LISTER` into the
  managed block so the answer survives a re-run.
- `smart-doctor` now reports the lister, and warns when the list has been handed
  to a picker that is **not loaded** — and that alarm now outranks every other
  verdict, because "nothing will be drawn at all" is a worse state than two
  lists. The first version of the verdict reasoned only from "how many foreign
  hooks are loaded", which is legitimately zero in exactly that situation, so it
  announced a healthy shell while no list could possibly appear.

### Changed

### Changed
- **Single-column is now opt-in (default OFF).** v2.2.3 shipped it on, which was
  the wrong default: a vertical list can only be produced by *generating* the
  candidates, and generating them costs real functionality.
  - It **bypasses `_main_complete`**, so for the contexts it covers you lose
    candidate **descriptions**, `list-colors` colouring, grouping and your
    `matcher-list` — the documented fuzzy matching does **not** apply to
    generated candidates.
  - Only commands / functions / aliases / builtins, filesystem paths and `cd`
    recent directories are generated. Everything else (git subcommands, ssh
    hosts, `--options`, `sudo …`) falls through to the native grid, so **the
    popup changes shape while you type** — which is easily mistaken for a second
    list appearing.
  - A candidate wider than the terminal is clipped (no ellipsis).
  Nothing was removed: `SMART_MENU_SINGLE_COLUMN=true` still draws exactly the
  vertical list v2.2.3 shipped. The installer now asks (default: **no**) with the
  trade-off stated in the question.
- `tests/e2e-tmux.sh` grows to **41** assertions. Scenario 10 asserts the
  single-column contract in order — the default is the grid (10a), opting in
  draws one per line (10b), turning it back off restores the grid (10c); 10a and
  10c are what make 10b falsifiable instead of vacuous. Scenario 11 walks the
  lister switch BEFORE -> OFF -> BACK ON, which is the only structure in which
  the middle step means anything (without the step back, "no rows" is equally
  satisfied by a shell that simply stopped completing), and it also asserts the
  inline suggestion survives the handover.
- The v2.1.6 A/B baseline was **re-measured, not scaled**: **20/41**. On v2.1.6
  neither the popup nor the switch exists, so 10a/10b/10c fail and most of
  scenario 11 does too. Three checks in that region still pass, and **only one of
  them is genuine** — the inline suggestion surviving the handover (v2.1.6 has
  `POSTDISPLAY` as well). The other two — "no row holds two candidates" (10b) and
  "we draw no list after handing over" (11b) — pass *vacuously*, because that
  build draws no list at all. Telling those apart is exactly why the baseline has
  to be run rather than derived from an earlier fraction.
- `tests/test-menu.zsh`: 144 -> 183. Scenario 5 now DRIVES the `smart-lister`
  CLI for every accepted spelling and asserts that all three places encoding the
  list agree. They are written out separately (the normaliser, the "is it
  recognised" check, and the CLI) and had already drifted: the CLI accepted `on`
  while the recogniser rejected it — so `smart-lister on` succeeded and the very
  next `smart-lister` contradicted it — and `no`/`false`/`0` were fzf-tab to the
  helpers but fell through to the status output in the CLI. A hand-copied
  spelling list cannot catch that, which is precisely how it got through the
  first time. `smart-doctor`'s new handover verdict is pinned in scenario 13b,
  including its false-positive side (a picker that IS loaded must clear the
  alarm).
- `tests/test-config.zsh`: 39 -> 43. New scenario 5 pins the one value that has
  now drifted twice: the single-column default as stated in all five READMEs
  must equal `lib/config.zsh`'s actual default, proved falsifiable by checking
  that the opposite value is NOT found.
- The installer test suite grows to **58** and cross-checks the derived
  `SMART_MENU_LISTER` default against `lib/config.zsh`.
- Totals: **590 assertions** (532 across the nine zsh suites + 58 in the
  installer suite); e2e **41/41**.

## [v2.2.3] - 2026-09-16

### Fixed
- **`Delete` left a stale inline ghost.** Backspace was wrapped, but `Delete`
  (`ESC [ 3 ~`) was not, so deleting a character after recalling a history entry
  left the previous suggestion frozen on screen. `Delete` is now wrapped exactly
  like Backspace (both keymaps) and handed back on unbind.
- **The single-column popup was silently rendering as a grid.** The pad width was
  computed as `local cols=... pad="$cols"` on ONE line — and every expansion of a
  `local` command happens *before* either assignment, so `pad` was empty and
  `${(r...)…}` padded to width 0. The list stayed multi-column while the code
  looked correct. The width is now passed to the padding by name
  (`${(r.cols.. .)...}`).

### Added
- **Single-column (vertical) live popup** — `SMART_MENU_SINGLE_COLUMN`, default
  `true`. The type-to-popup draws ONE candidate per line instead of zsh's native
  multi-column grid. Candidates are generated directly (commands / functions /
  aliases, filesystem paths, `cd ` recent directories) and every *display* string
  is padded **or clipped** to exactly `COLUMNS` wide, which mathematically leaves
  room for a single column. Set it to `false` for the native grid.
  - Why generated rather than captured: shadowing `compadd` with a function makes
    some zsh builds stop adding matches *entirely* (measured), which would
    silently empty the popup.
  - The typed word is escaped before it reaches the glob engine: a typed `[` used
    to build the pattern `[*`, and a bad pattern is not a nomatch — it aborts the
    generator and prints `bad pattern:` on every keystroke. A leading `~/` is
    deliberately left unescaped, though, or every `~/…` candidate would vanish.
  - Fall-through is preserved: contexts the generator cannot cover (git
    subcommands, ssh hosts, option strings) still run your real completion.
- **`smart-doctor`** — prints every fingerprint that can put a second candidate
  list on screen: whether `_main_complete` / `compadd` / `_complete` are still
  zsh's stock entry points, whether zsh-autocomplete / zsh-autosuggestions /
  fzf-tab / syntax-highlighting are loaded, who owns `Tab` per keymap, the
  zstyles that can enable a list, and this plugin's own state — then a verdict.
  Read-only, so it is safe in a half-broken shell.
- **Interactive installer options.** fzf-tab, the Tab menu, the single-column
  layout, recent directories, Up/Down history search, zsh-vi-mode and the
  suggestion source are all asked at install time, and the answers are written
  into a managed block in the generated `~/.zshrc`. Both `install.sh` and
  `install-entware.sh`.
  - The block sits **above** the plugin load on purpose: some options (notably
    `SMART_MENU_HISTORY_KEYS`) are read while the plugin installs its key
    bindings, so writing them afterwards would be silently ignored.
  - fzf-tab is opt-in (default **off**) and, when chosen, forces the built-in
    selectable menu off — running both is exactly how two listers end up
    fighting over the same screen area.
  - `NONINTERACTIVE=1` takes the documented defaults.

### Changed
- **Fixed the `starship.toml` template.** The top-level `format` used
  `[$user]($style)`, but `($style)` is only valid *inside* a section, so the
  username was swallowed. Line 1 is now `[$user] › $directory`, line 2
  `$character`.
- The installer's `.zshrc` template gained an explicit managed options slot, and
  the trailing "Optional:" comment block was replaced by the knobs that are *not*
  asked as questions.

### Tests
- `tests/test-menu.zsh`: 109 -> 144. New scenario 13b (`smart-doctor`) and
  scenario 14 (single-column candidate generation, plus the single-column
  invariant: every display string is exactly `COLUMNS` wide, and the padding
  never touches the text that actually gets inserted).
- `tests/test-zle.zsh`: 93 -> 102. `Delete` bound in both keymaps, released on
  unbind, and silent on stdout.
- `tests/test-config.zsh`: 37 -> 39. `SMART_MENU_SINGLE_COLUMN` default and
  override.
- **`tests/test-installer-options.sh` (new, 54 assertions, bash)** — extracts the
  installer's option machinery and drives it against throwaway files. It pins the
  one property that is invisible in the source: the managed block must land
  **before** the plugin load, and a re-run must be idempotent. It also
  cross-checks every installer default against `lib/config.zsh` — that check is
  what caught the Tab-menu default disagreeing with the shipped value.
- `tests/e2e-tmux.sh`: 29 -> 33. **10** asserts six candidates occupy six rows,
  all are listed, and no row holds two; **10b** turns on
  `SMART_MENU_SINGLE_COLUMN=false` and asserts the grid comes back, which is what
  proves 10 is capable of failing.
- Totals: **538 assertions** (484 across the nine zsh suites + 54 in the
  installer suite); e2e **33/33**.

## [v2.2.2] - 2026-09-16

### Fixed
- **A `Tab` followed by `Enter` now runs the line**, instead of merely redrawing it.
  After any completion the first `Enter` was swallowed by the accept-line widget
  (it treated the completion as still active and only refreshed the display), so a
  completed `cd …` needed a *second* `Enter` to execute. The widget now clears its
  own state and calls `zle .accept-line` directly. This is a **pre-existing bug** —
  it reproduces on v2.2.1.

### Added
- **Recent-directory candidates** (`lib/engine/recent.zsh`, `SMART_RECENT_PATHS`,
  default `true`). While completing a `cd` / `pushd` / `chdir` argument, the
  directories you have actually been in are offered as candidates, and they are
  listed immediately on the **empty word** after `cd ` — the one place where an
  empty word is worth listing. It is a completer prepended to
  `zstyle ':completion:*' completer`, so it composes with your own chain and is
  removed cleanly on `smart-recent off` / `smart-disable`.
- **It only reads.** The data is zsh's own recent-directories database — the one
  `cdr` and `~[1]` use — and the plugin never writes to it. `SMART_RECENT_PATHS_MAX`
  (default `20`) caps how many are offered; `smart-recent status` reports how many
  are usable right now.
- **`smart-recent on|off|toggle|status`** runtime command.

### Changed
- **Fuzzy matching is documented, not implemented.** The live popup runs *your*
  completion system, so a `zstyle ':completion:*' matcher-list` already applies to
  it — there is no fuzzy-matching code here by design, and adding some would only
  fight compsys. The README "Optional extras" section shows the one line to set.

### Tests
- `tests/test-recent.zsh` (38 assertions): `cd`-argument detection, database parsing
  (spaces / quotes / XDG location / stale entries), and — pinned as a regression —
  that the completer is wired through `zstyle ':completion:*' completer` and **not**
  a `$completer` array (which does not exist; the code "looked wired" and did
  nothing).
- `tests/e2e-tmux.sh`: **8b** (Tab-then-Enter runs the line) and **9** (recent dirs
  listed on `cd `, Tab completes the path). 29 assertions; **17/29 on v2.1.6**.

## [v2.2.1] - 2026-09-16

### Fixed
- **The live popup no longer eats a keystroke.** Scoping `LISTMAX=-1` around the
  listing call — the previous way of suppressing zsh's "do you wish to see all N
  possibilities (M lines)?" prompt — corrupts ZLE's next input read: typing
  `git status` left `gitstatus` in the buffer and the shell ran the wrong
  command. `LISTMAX` is no longer touched at all. The prompt is prevented instead
  by declining to draw an oversized list (`SMART_MENU_MAX_MATCHES`, default
  changed from uncapped to `100`), the only setting measured clean for both short
  candidate lists and a 1200-entry directory.
- `smart-menu status` and the tick debug trace now tell "below the minimum" apart
  from "over the cap"; both used to be logged as `below min`, which sent
  debugging in the wrong direction.

### Added
- **`SMART_SUGGEST_STRATEGY`** (`history` | `history,completion`, same names as
  zsh-autosuggestions). With `completion`, the ghost can suggest paths, options
  and subcommands that are not in your history, by asking the completion system
  for the unambiguous prefix of the word under the cursor.
- **Named, rebindable widgets**: `smart-accept-suggestion`, `smart-accept-word`,
  `smart-execute-suggestion`, `smart-suggestion-toggle`.
- **`SMART_MENU_HISTORY_KEYS`** (default `false`): with `true`, up/down
  prefix-search your history while the line is non-empty — zsh-autocomplete's
  headline behaviour — falling back to plain history navigation on an empty line.

### Tests
- `tests/e2e-tmux.sh` now asserts **buffer integrity** in a real terminal:
  typing must never lose a character, and the command that actually executes is
  the one that was typed. The previous suite only checked whether a list was
  drawn, so it stayed green while the popup was corrupting every command line.

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
