# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this
project adheres to [Semantic Versioning](https://semver.org/).

## [v2.4.2] - 2026-09-26

### Fixed
- **Indexing history evaluated it: the suggestion was never missing, the plugin
  was dead.** Both history backends compared each command's count the same way,
  `(( _SMART_BUILD_FREQ[$cmd] > max_freq ))` (the atuin one spells it `$command`).
  Inside `(( ))` — and inside `$(( ))` — zsh does not substitute a *bare*
  parameter that appears as a subscript: it expands the text and then re-parses
  that text as an arithmetic expression. Here the text was a whole command line
  from history. Traced on the reporting machine (zsh 5.9, 912 history lines), the
  evaluation reached
  `((  _SMART_BUILD_FREQ[functions -T _smart_cmds_rebucket] > max_freq  ))`, so
  arithmetic was being run over shell syntax. Three things followed from that, and
  they arrived as one symptom:

  1. A history line containing `$(…)` had that substitution **executed** during
     indexing. Measured locally against a seeded history file: the marker file the
     line named existed afterwards, and the new atuin scenario reproduces it as a
     `FAIL` on the pre-fix code.
  2. A line with an unbalanced `]` raised `bad math expression: illegal
     character: ]` — which is what the user saw. Every caller discards the
     rebuild's `stderr`, so the only trace was an empty index.
  3. On that user's history the evaluation **never returned**: the rebuild had to
     be interrupted with Ctrl-C, on every command, because `_smart_bootstrap_once`
     removes itself from `precmd_functions` only *after* the rebuild, and a
     `count == 0` index makes the keystroke path retry a full rebuild.

  Because the same bootstrap installs the ZLE wrappers *after* the rebuild, the
  widgets were never bound (`_SMART_EVT_CAPTURED=0`): no inline grey suggestion,
  no menu, nothing — `smart-status` read `history indexed: 0`, `last
  rebuild: 0`, `last suggestion []`. Neither of v2.4.1's two colour fixes was
  involved; that user's session reported `memo_ok=1 color=fg=110` and 256
  terminfo colours, i.e. the branch that was already correct.

  The count now travels through a scalar, which arithmetic only ever reads as a
  number: `_SMART_BUILD_FREQ[$cmd]=$f` and `if (( f > max_freq ))`. Same shape in
  `_smart_history_backend_atuin_build`, and in `_smart_history_rebuild`'s persist
  loop, where `$(( base - _SMART_BUILD_REC_RANKS[$c] ))` had the same
  subscript-under-arithmetic problem with `$c` a full history line. That is also
  the house style the incremental upsert path already used, so the two write paths
  now agree.

### Added
- `tests/test-history.zsh` 场景 10 (28 → 34 assertions) and `tests/test-atuin.zsh`
  场景 7 (26 → 31) seed a history that contains one line with an unbalanced `]`
  and one line carrying `$(touch <marker>)`, then run the real rebuild — the zsh
  suite through `fc -R` in a non-interactive shell, the atuin suite through a
  throwaway SQLite database — and assert: the marker was not created, the rebuild
  wrote nothing to `stderr`, the hostile line is stored verbatim as a key, and the
  frequencies came out right.

  Measured on the pre-fix tree (zsh 5.9): the atuin scenario reports 3 of its 5
  new assertions failing — `敌意命令行没有被执行 got=[yes] want=[no]` (the
  substitution ran), `构建过程 stderr 干净 got=[97] want=[0]`, and
  `重复行 freq 累加 got=[1] want=[2]` — the increment line
  `$(( _SMART_BUILD_FREQ[$command] + 1 ))` raised, so the duplicate was never
  counted. The history scenario is worse than a red assertion: the run stops at
  the scenario header, leaving 180 bytes behind that read
  `_smart_history_backend_zsh_build:19: bad math expression: operator expected at
  '( ; while ...'` and `_smart_history_rebuild:67: …`, plus the marker file it had
  created.

  What they do **not** cover: the shape the reporting user hit, where the
  evaluation never returned at all. That was observed on their machine and is not
  reproduced here — locally these same two fixture lines fail loudly instead,
  which is what caught the bug. Asserting on a non-return would mean hanging the
  suite or putting a wall-clock bound in it, and a time-bound assertion is a flake
  with a name. Cost: 0.5 s and 0.3 s locally. To remove: delete the blocks headed
  `场景 10` / `场景 7`.

## [v2.4.1] - 2026-09-26

### Fixed
- **The suggestion lost its colour on zsh 5.8 and 5.8.1, and the cause was the
  marker that named it.** `region_highlight` entries are re-rendered from their
  attribute bits, so a highlighter that wants to find its own entry again has to
  leave something in the text — we wrote `… fg=8 memo=zsh-smart-complete:suggestion`.
  `memo=` is parsed only by zsh 5.9 and later (`Src/Zle/zle_refresh.c`); on 5.8,
  `Src/prompt.c: match_highlight()` reaches `else if (*teststr) break;` *before* it
  stores the colour, so any token after the colour that is not a comma throws away
  the rest of the scan. The entry was stored with **no** attributes — measured as
  `rh=1 12 none` in a session whose own `terminfo[colors]` was 256, which is also
  what ruled out the terminfo theory the first two fixes had chased. The marker is
  now written only when the running zsh can carry it; on older builds the module
  identifies its entry by remembering what it wrote, and where that began, because
  a completion-list redraw clips a range back to the end of `BUFFER` and the
  remembered text stops matching. What the README promises holds on both branches:
  one entry at most, and only that one removed.
- **The version-matrix cells were red for three reasons that belong to the host,
  not to the code.** The shared fixture farm put `opkg` on `PATH`, so `install.sh`
  handed over to `install-entware.sh` on every Linux run — the script under test
  had been swapped by its own fixtures, and the "half-written `.zshrc`" that looked
  like a Linux-only installer bug was the *other* installer's file, which carries
  no managed markers by design. `tools/check-module-globals.sh` extracted its
  documented key list with a `{n,}` interval expression, and the `awk` of a
  Debian/Ubuntu image is mawk, which ignores intervals outside POSIX mode: it
  extracted zero keys, and every dead-key assertion passed by checking nothing. Two
  installer suites needed `python3` and `ps`, which a minimal image does not ship.
  The cells stay blocking — the colour bug above is exactly what only they could
  find.

### Changed
- **A red job now names every failure it has.** Reading a job log from outside the
  runner needs authentication; the annotations of its check run do not. Three jobs
  each carried their own copy of that packing and each lost part of what it found:
  `tail -n 5` over a broad grep published one failing assertion out of seven (two
  runs came back byte-identical, because nobody could read them), the end-to-end
  step's `tail -n 20` filled its slots with quoted pane text and dropped the
  failures, and the release gate — which had none of this — said only `Process
  completed with exit code 1` for the v2.4.0 failure. `tools/annotate.sh` is now the
  single implementation: it folds a long field into several annotations at *entry*
  boundaries (cutting at a column interleaves two assertion names and leaves neither
  readable), and publishes one `name:passed/failed` pair per suite even when
  everything is green — which is what makes the assertion count quoted in README
  checkable from the run that measured it. It always exits 0: a diagnostic that can
  fail a build is a second build system.
- The v2.3.0 entry stated that the matrix images package zsh 5.7.1 / 5.8.1 / 5.9.
  Each cell's own `zsh --version` reports **5.8** / 5.8.1 / 5.9, so the number for
  `ubuntu:focal` was wrong; it now reads 5.8 in all five languages, and the workflow
  says where those numbers come from.

### Added
- `tests/test-annotate.sh`: 39 assertions over fixture logs, including that no
  annotation is wider than the script's own budget — measured on the bytes the tool
  really emits, since an assertion against a re-implementation of the packing would
  pass however the script folded. `tests/test-display.zsh` grew a scenario (55 → 74
  assertions) that forces the no-marker branch and checks that the entry does not
  stack one per keystroke, that a clipped leftover is still recognised and removed,
  and that the version gate reads `5.10` as newer than `5.9` rather than as `5.1`.

## [v2.4.0] - 2026-09-26

### Fixed
- **The installer could finish by writing an empty settings file, and then refuse
  to ever fix it.** The last-resort path in `_install_user_settings` — taken when
  the repo's template files could not be fetched — emitted its starter content
  with `print -r --`. `print` is a zsh builtin, not a program on `PATH`, so in a
  bash script it is exit 127 on any machine that does not happen to have
  something named `print` installed: the run had already rewritten `.zshrc` by
  then, and the zero-byte file it left behind satisfied the "create it only if it
  is absent" guard, so no later run repaired it either. Both installers now use
  `printf '%s\n'`. This was found by running the installers, not by reading them.

- **A mirror URL handed to the installer was treated as code, not as data.**
  `SMART_INSTALL_GH_MIRROR` and the "enter your own mirror" answer are both fed
  into the download shim that rewrites the URLs `curl` / `wget` are called with —
  and that shim was generated from an **unquoted heredoc**, with the value
  interpolated into the script text. `https://x.example/'; touch ./pwn; '` was
  therefore not a URL but three statements, executed at install time; on top of
  that, anything downloaded through a mirror the installer did not pick is run by
  `_run_remote_script`, so the same string also decided where the executed code
  came from. The shim now reads its configuration from a four-line data file with
  `read -r` and never interpolates it, and both installers check the value through
  `_mirror_prefix_ok` before using it: an `https://` host, an optional port, an
  optional path — nothing else. Plaintext `http://` is refused deliberately: the
  fetched scripts get executed, so the transport is not something a typo should be
  allowed to downgrade. Test section 27 builds a shim from a hostile value and
  asserts the payload stays in the data file, that the real downloader is still
  handed the original URL, and that nothing was created.
- **An install that failed halfway left the damage in place.** Both installers
  write `.zshrc` as a *sequence* — options block first, then the loader block.
  Every single write is a rename, so no one of them can truncate the file, but an
  abort between two of them left a `.zshrc` that parses, starts a shell, and does
  not load the plugin. The `.bak.<timestamp>` next to it undoes nothing: nothing
  points at it, and the run that made it had already stopped. `_guard_config_write`
  now snapshots the file before the first write and an `EXIT` trap puts that
  snapshot back on a non-zero exit — or deletes the file the installer created,
  because "there was no `.zshrc` before" is a state worth restoring too.
  `_release_config_write_guard` disarms the trap once the last write of the
  sequence has landed, so a failure in a later, unrelated phase cannot talk the
  installer out of the config the user asked for. Section 25 keeps a control run
  without the guard, which is what makes the rest of the section mean something.
- **A template that produced no content could be written over a working config.**
  Every arm of `apply_template` redirected straight into `$dest`, so an
  unrecognised source prefix — or a fetch that came back empty — truncated the
  user's file first and failed afterwards. It now always writes
  `<dest>.zsc-new`, refuses with a translated error when that file is empty, and
  puts it in place with a single `mv -f` in the destination's own directory.
- **Two globals were reachable, used, and declared nowhere.** Every module turns
  on `no_warn_create_global`, which means the first write to an undeclared name
  silently makes it a global — so `_SMART_PROBE_SUFFIX_RET` existed only as a side
  effect of the function that returns through it, and `_SMART_RH_MARKER` only as a
  top-level assignment. Both now say `typeset -g` where they are defined. Neither
  misbehaved in a running shell; both were invisible to anything that answers
  "what state does this module own" by reading declarations, which is exactly the
  audit that found them.
- **The state container's documented key list was wrong in four places.** The
  comment block that documents `_SMART_STATE` for a future port named
  `history.freq` for a sub-map the code calls `history.frequency`; listed
  `history.first_char`, which nothing had ever written (the `_SMART_CMDS_FIRST`
  buckets superseded that plan years ago); promised a `last_err` slot no code
  writes or reads; and omitted three sub-maps that are live on every rebuild —
  `history.cwd`, `history.host`, `history.exit`. `suggestion.source`'s documented
  value list also left out `completion`, which is what the native-menu path
  stores. A document that presents itself as a spec fails silently, so the
  checker below now rejects any documented key with no writer or reader in `lib/`.
- **In the vertical popup the word you had typed was used as a pattern.** The
  command list was filtered with `${(M)_sc_out:#${w}*}`, which drops the typed
  text into a glob — and `[ ] * ?` are not the whole alphabet there. Under
  `EXTENDED_GLOB`, which several popular frameworks turn on, `#`, `^`, `(` and
  `<->` are pattern syntax as well, so an unescaped prefix could match commands
  the typed text never contained (measured: `zsc#` matched `zsc_probe_alpha`) or
  be a bad pattern outright. The command branch now escapes the word with
  `${(b)…}`, exactly as the path branch already did, so `git#` means the command
  `git#`: no literal match, nothing generated, and the word falls through to the
  native grid like every other context this mode does not cover. Section 14h of
  `tests/test-menu.zsh` asserts the escaped prefix matches nothing, that stderr
  stays empty for it, and that a real prefix still matches — the last one being
  what stops the first two from passing vacuously.
- **Two runs in the same second could overwrite each other's backup of
  `~/.zshrc`.** The uninstall copies the config to `.zshrc.bak.<epoch>` before
  stripping the managed blocks out of it, and the install copies it to a name of
  that same shape — so the name is only unique when a second really does separate
  the runs, while "install it, then undo that install" is exactly the pair that can
  share one. `cp -p` then replaced the copy that was already sitting there, and what
  it replaced was the one version of a hand-written config the uninstaller promises
  to keep. The copy now steps aside to `.bak.<epoch>-1`, `-2`, … when the name is
  taken. This surfaced as a coin flip in `tests/test-installer-sandbox.sh`: section
  8 counted the backups left after a no-op uninstall and expected exactly one, which
  only held when the install's and the uninstall's copies collided in the same second
  and erased the evidence of the other. It now compares against the set the previous
  run left behind, and the assertion that read `find | head -1` as "the uninstall's
  backup" reads `sort | tail -1` instead — on a run where the install had also backed
  the config up, the first file `find` handed back was the install's copy of the
  *seed*, which holds no managed block at all. Same coin, other side.

### Added
- **`tests/test-installer-sandbox.sh` — the installers are now executed, not just
  inspected.** Everything else in `tests/` either sources a `lib/*.zsh` module or
  lifts one function out of `install.sh` and drives it against a fixture, so
  nothing had ever run the installer as a whole: not the code that wires the
  functions together, not the order they run in, not the fact that the file is
  executed by **bash**. The new suite runs both installers under `env -i` (no
  inherited environment) with `HOME`, `ZDOTDIR` and `XDG_*` inside a fresh
  `mktemp -d`, and a stub bin dir first on `PATH`, so a run cannot reach the
  network or a package manager: every `curl` / `wget` / `git` / `brew` / `opkg`
  call is logged instead of performed, and that log is itself asserted (the
  mirror speed test must have run; `SMART_INSTALL_GH_MIRROR` must visibly rewrite
  the clone URL; the Entware script must stop at its `opkg` guard without
  touching `.zshrc`). Twelve installer paths — defaults, four combo presets, five
  UI languages, two network branches — are each checked for exit code, for
  `unbound variable`, for `command not found`, and for what a successful install
  leaves behind (both managed `.zshrc` blocks, a non-empty `settings.zsh`). The
  grep that reads the sources also blanks heredoc bodies first, because these
  scripts *embed* zsh config and those lines are supposed to be zsh; a paired
  assertion proves the filter hides template zsh without hiding executed zsh, and
  that it preserves the line count so a reported line number still points at the
  file. 55 assertions.
- **`tests/test-installer-shared.sh` — the contract between the two installers is
  checked instead of assumed.** It verifies that every message key a file asks
  `msg()` for is one its own `_msg()` defines (an unknown key prints itself, so
  this is the only thing that catches the class), proves the lint is not vacuous
  with a probe file, and compares the two files function by function with a
  heredoc-aware parser: what matches goes through the shared core, what diverges
  must appear on a list that carries the reason. 13 assertions.

- **`--uninstall`, or `SMART_UNINSTALL=1` for the `curl | bash` path where argv
  does not survive.** It removes exactly what the installer wrote — the two
  managed `.zshrc` blocks, the plugin checkout, `settings.zsh` and the
  `zsc-settings` symlink we created — and nothing else. Packages (fzf, starship,
  atuin, zinit) are left installed, `starship.toml` and every `.bak.*` file are
  left on disk: they are shared with the rest of the shell and may well have been
  there first. `.zshrc` is copied to a timestamped backup *before* it is edited,
  and the uninstall refuses to modify it if that copy cannot be made. A headless
  run counts `SMART_UNINSTALL=1` as the confirmation; in a terminal it asks. The
  strip pass is the inverse of `_upsert_options_block`, and it also retires the
  pre-marker form — `zinit ice` plus `zinit light imonior/zsh-smart-complete` —
  **as a pair**, because an orphaned `zinit ice` silently re-styles whichever
  plugin loads next. Blank lines that only existed in front of our own blocks go
  with them; a blank line between two of the user's stanzas stays where it was.
  `tests/test-installer-sandbox.sh` now installs into a sandbox home seeded with
  lines the installer never writes and asserts the config comes back **byte for
  byte** what it was.
- **Two dead-code lints, because the class of rot they catch is invisible from
  the source.** One reports a function an installer defines and never calls; the
  other reports a message key defined in a catalog and called by *neither*
  installer — the catalogs are shared supersets by design, so that check has to be
  cross-file. Each ships with probes for its own detector (a live function versus a
  dead one, a `read` inside a heredoc versus outside, a key prefix versus the whole
  word) and with an assertion that the catalog walk really found a few hundred
  keys, so the lint cannot pass by having found nothing. What it turned up:
  `_cleanup_old_baks` (91 lines that deleted every `~/.zshrc.bak.*` it could find,
  with no prompt — unreachable, because it referenced an unset array and would
  have aborted under `set -u`), `_backup_if_normal`, `install_or_upgrade_pkg`, and
  34 catalog entries with no caller in either script.

- **`tools/check-module-globals.sh`, so a new global has to justify itself.**
  `lib/state.zsh` claimed to hold all mutable cross-module runtime data and that
  no standalone `_smart_thing=foo` existed anywhere else in the codebase; 66
  globals outside it disagreed. The comment was the defect rather than the count:
  a reader who trusted it had no way to find the state that was really there, and
  a writer who added one met no friction. The rule now states the boundary it
  actually keeps — runtime *state* in the container, everything else in the
  register at the bottom of that file with a reason — and the checker enforces
  both directions: an unregistered global fails, a register line that matches
  nothing fails (that is how a rename would otherwise leave the register
  describing a codebase that no longer exists), an entry without a reason fails,
  and a documented state key nobody writes or reads fails. Migrating the
  declarations themselves was measured before being declined: a container
  subscript costs well under a microsecond per read against ~0.2 µs for a plain
  global, so performance was never the argument — lifecycle was. The per-keymap
  binding snapshots are captured from the user's own keymaps once per shell, and
  `lib/state.zsh` is sourced *before* `lib/event/zle.zsh`, so storing them in a
  container that `_smart_state_reset` empties would delete data nothing else can
  supply; the out-parameter slots (`_SMART_BUILD_*` and the fork-free `_scan`
  returns) live exactly as long as one call. `tests/test-module-globals.sh` adds
  84 assertions, most of them aimed at the checker rather than at the tree,
  because a lint nobody can prove works is a lint that reports green. It runs as
  part of `tests/run-all.sh`, so CI picks it up by discovery.
### Changed
- **Both installers run under `set -u`** (they were `set -eo pipefail`). The flag
  is only honest while something walks these branches, which is what the suite
  above is for. Getting there took three fixes: eleven `MIRROR_TIMES[…]` reads
  now default with `:-999`, and two expansions that can legitimately see an empty
  array use `${arr[@]+"${arr[@]}"}` — bash 3.2, which macOS still ships, aborts on
  `"${empty_array[@]}"` under `-u` while `"$@"` stays safe.
- **There is one key-binding probe.** `lib/event/zle.zsh` carried a byte-for-byte
  copy of `lib/engine/native.zsh`'s `_smart_current_binding`, down to the two
  guards that exist only because of past regressions (read the *last* field of
  `bindkey`'s echo, never the key text; treat `undefined-key` as unbound; never
  accept one of our own widgets as an "original"). A fix landing on one copy
  silently left the other broken. The duplicate is gone and the surviving
  function documents itself as the only one; `_smart_event_capture_originals`
  calls it around twenty times per shell.
- **The menu clock no longer forks while you type.** `_smart_menu_now_ms` returned
  its value through command substitution, so the two reads per listing tick cost
  **349 µs each**. It now has the worker/wrapper split the lister uses:
  `_smart_menu_now_ms_scan` publishes into `_SMART_MENU_NOW_MS` for the hot path,
  and the printing wrapper stays for `smart-doctor`, status output and tests.
  Measured **9.9 µs** per call.
- **The parts both installers share are written once.** `install.sh` and
  `install-entware.sh` duplicated ~80 functions because each is advertised as a
  standalone `curl -fsSL … | bash` script and so cannot source a sibling at
  runtime. That is a real constraint, but it was being honoured by copy-paste, and
  the copies had already drifted — the same string lived under two different
  message keys, and `msg()` answers an unknown key by printing the key itself, so
  a typo shows `mirror.unavailable_line` in the user's terminal instead of failing.
  Now `lib/install/core.sh` holds the 30 environment-independent functions
  (mirrors, curl wrappers, download shim, language menu, option blocks) and
  `tools/build-installers.sh` splices it verbatim into both files between marker
  lines. The artifacts stay committed, because a user has no build step to run;
  `bash tools/build-installers.sh --check` is wired into CI, so a block that no
  longer matches its source is a failed build rather than a shipped defect. The
  21 functions that remain duplicated are environment-specific on purpose (opkg
  paths, `$HOME` vs `$ZDOTDIR`, the message catalogs) and are listed with their
  reason in `tests/test-installer-shared.sh` — new divergence fails the suite, and
  so does an entry on that list that has quietly become identical again. The
  refactor is measured rather than asserted: the set of functions with their body
  hashes, and the ordered sequence of every top-level statement in both files, are
  unchanged. One text change was in scope and made: entware's `_tty_read` comment
  now reads the way install.sh's does.

- **The four BEGIN/END marker constants are defined in the shared core now**, not
  at the point in each script that first writes a block. An uninstall has to
  recognise those blocks before anything is installed, and with the assignments
  still sitting near the end of a 4000-line script it could not.

- **`lib/state.zsh` documents how to read it, and who may clear it.** The
  accessors `print`, so calling one means a command substitution and a fork
  (~0.4 ms) — the file told modules to "read/write state through these helpers"
  while every hot path already indexed the arrays directly, which is the opposite
  advice and the kind that gets followed. The doc now states the real rule (write
  through the helpers, subscript on the keystroke path) with the per-read costs
  measured here: ~0.2 µs for a plain global, ~0.6 µs for a literal key, ~0.8 µs
  with the key in a variable, ~400 µs through `$()`. `_smart_state_reset`'s header
  also names its actual callers instead of `smart-reindex`: that command rebuilds
  through `_smart_history_rebuild`, which deliberately clears only the history
  slots it is about to refill, because a full reset would also drop `enabled`,
  `buffer` and the cursor bookkeeping the wrapper widgets compare against.
- **The vertical popup now keeps its shape while you keep typing.**
  `SMART_MENU_SINGLE_COLUMN` generated command names for the *first word of the
  line only*, and the recent directories for the *empty word after `cd ` only* —
  so `ls -la | gr` drew from the filesystem while the `gr` on a fresh prompt drew
  commands, and `cd Dow` answered with files in the current directory while the
  grid next to it was already offering `~/Documents`. Both halves of the feature
  agreed with the native completer; the vertical list had been the odd one out,
  and the observable symptom was the popup changing source under the cursor. A
  word is now a command position whenever the shell is still choosing one: after
  `|`, `&&`, `;`, and past any run of assignments and bare wrappers (`sudo`,
  `command`, `env`, `time`, `nice`, …).
  The recent directories answer a typed prefix as well, by full path or by last
  segment, and only for `cd`/`pushd`, only while `SMART_RECENT_PATHS` is on, and
  not once the word is an explicit path — the same four conditions the native
  `cd` completer applies, which is what keeps the two lists identical. What still
  falls through to the grid is documented rather than guessed at: git
  subcommands, ssh hosts, option strings, `~user`, and any word after a wrapper
  that already took its command (`sudo git`). One limit is asserted instead of
  hidden: `git log|gr` is *not* a command position, because the popup splits
  words on whitespace and its current word is `log|gr` — redefining "word" for
  one feature would move the whole popup, so the predicate stays conservative.
  It runs on every keystroke, so `tests/test-perf.zsh` gained a section for it
  (~19 µs per call on a two-word line, and a scaling bound against a long line)
  next to the behavioural gate. The claim now has an on-screen half too: scenario
  10b+ of `tests/e2e-tmux.sh` types six command names at the start of a line and
  again after a `|`, and requires six rows and no row holding two candidates in
  both cases — which is a real assertion, since with the old predicate the second
  line generates nothing at all and the terminal shows either no list or the
  grid. The default is still `false`.

## [v2.3.0] - 2026-09-24

### Fixed
- **A big history stalled the shell while the index was being rebuilt.** Two places built their result a piece at a time, and both re-copied everything they had so far: the stored list string (`joined+=$'\n'$v` per command) and the first-char bucket map, where an element-at-a-time build additionally has to walk a zsh array's linked list both when appending and when reading an entry back by position. Rebuilding the index on an 8000-command history cost **693 ms**, and 4x the index cost **14x** the time. Both now do their joining in one C-level pass (`${(F)…}` for the string, a `${(M@)array:#${key}*}` prefix projection per bucket), the same 8000-command rebuild costs **30 ms**, and 4x the index costs 4x. At the 20000-command end of the range this is the difference between a rebuild you never notice and one that freezes the prompt for seconds. The projection also has to stay literal about the key: a bucket for commands starting with `*` must hold only those, which is asserted for every glob-magic character.
- **Pressing Enter cost a full scan of the index, twice.** Recency was stored as a *rank* — every command's position in a recency-sorted array — so promoting one command to newest meant re-stamping all the others, and membership meant finding it in the array first. Both were O(index) per Enter: 50 repeated commands on an 8000-command index cost **9.8 seconds**, and with the periodic rebuild switched off, each *new* command additionally copied the whole array to enforce the cap (**19.3 seconds** per 100 of them). `history.recency` now holds a monotonic **last-use tick** and the engine compares ages (`history.tick - stored tick`), so an Enter stamps one slot and touches nothing else; `_SMART_CMDS` is append-only membership, recency order lives in the buckets, and the eviction is a `shift`. The same 50 Enters now cost **32 ms**, 100 new commands at the cap **12 ms**.
- **Every keystroke forked subshells to read values that were already in memory.** The display and event layers asked for state through `$(_smart_state_get …)` and `$(_smart_menu_lister)` — nine such calls on the popup and repaint path, each one a `fork()` measured at ~0.41 ms on this machine, and one of them (`_smart_menu_word`) was also the reason a probe could never drive ZLE from inside `$()`. The hot paths now subscript `_SMART_STATE` and `_SMART_MENU_LISTER_RET` directly; the printing wrappers remain for status output, `smart-doctor` and tests, with a comment on each side saying which is which.
- **On Entware installs the settings block could land anywhere — or nowhere.** `install-entware.sh` never defined `ZSC_BLOCK_BEGIN` / `ZSC_BLOCK_END`, and `_upsert_options_block` compares against those names: with the variable empty, `grep -qF "" "$file"` matches **every** file, so the "there is a managed loader block, insert above it" branch was always taken and ran as "insert before the first empty line". A freshly generated `.zshrc` has no empty line, so the options were silently dropped; a dotfile shared from a PC got them at an arbitrary position instead of above the plugin load, where a few of them are read during bind-key setup. The two markers are now defined with the same values `install.sh` writes, both installers are checked for all four marker constants, and every branch of `_upsert_options_block` is driven against fixtures (including a marker-free file with no blank lines).

### Added
- **`tests/test-state.zsh`, `tests/test-display.zsh`, `tests/test-native.zsh`.** Three modules had no direct tests: the state container (every other module writes through it, and its bucket mirror was just rewritten), the display layer (a wrong `region_highlight` entry costs the ghost its colour, a leaked one costs a syntax highlighter its entries — none of which a suggestion-level test can see), and the native Tab bridge (whose whole contract is that Tab keeps doing what it did before the plugin loaded, including for users who never ran `compinit`). The new suites run in a plain `zsh` script: `$bindkey`, the keymaps and `$widgets` all work there, and `zle` — the one thing that needs a terminal — is mocked by a function that records the widget it was handed.
- **`tests/test-perf.zsh` — a complexity tripwire.** Every bug fixed above was invisible to a behavioural test: the output stayed perfectly correct, the only symptom was seconds. It times the three operations that run while you type, on a synthetic index shaped like a real one (13 distinct verbs, so bucket work and full-array work can be told apart), asserts a wall-clock cap for each plus a 4x-size scaling ratio, and prints what it measured so drift is visible before anything fails. Caps sit 5-8x above the measured time, so CI noise cannot trip them. It fails on the tree before these fixes: `FAIL l_set history.cmds at 8000 commands 692.6 ms (cap 500 ms)`, `FAIL 50 upserts over a 8000 command index 9772.7 ms (cap 500 ms)`.
- **CI now has three jobs, split by what each can prove.** `test` is the gate (macOS + Linux). `zsh-versions` runs the same suite inside `ubuntu:focal` / `ubuntu:jammy` / `debian:bookworm`, i.e. against packaged zsh 5.7.1 / 5.8.1 / 5.9, because much of this codebase documents a claim as "measured on zsh 5.9" while only ever being verified on one build per OS. `e2e-advisory` runs the tmux end-to-end suite **non-blocking**: it is the only suite that can see a rendered screen, and also the only one that drives a real terminal with wall-clock waits, so its flake rate has to be measured before it may turn a good change red. The release workflow gained a `gate` job that `release` depends on — the suite must be green, `VERSION` must match the tag, and the CHANGELOG must have a section for it; publishing to the tag people actually install from used to be unconditional.

### Changed
- **`./tests/run-all.sh` is the one command.** It discovers `tests/test-*.zsh` (zsh) and `tests/test-*.sh` (bash), takes an optional substring filter and `-v`, and sums each suite's assertion counts. The CI job used to enumerate twelve files by hand, next to a comment admitting that a new file nobody added there is silently never run — which is how two of the modules above went untested.
- **The READMEs no longer pin a hand-counted test summary.** "12 test files, 804 assertions" was wrong on the first commit that added a suite; the line now points at the runner that prints the measured totals. Updated in all five languages.
- **Duplicated code and comments removed**, including a second `zle -N _smart_native_complete` (registering the same widget twice), a verbatim copy of the post-listing `region_highlight` rationale in the reverse-Tab widget, and the lister-spelling note that had been copied into three places with two different descriptions of itself. The accepted spellings are now stated once, and a test drives `smart-lister` to assert all copies agree.
- **`smart-doctor` no longer leaves a function behind in your shell.** Its prefix probe was defined at the top level of the command, so after a plain `smart-doctor` run the function stayed in the session; it is now named with the plugin's own prefix and `unfunction`ed when the command finishes.

## [v2.2.11] - 2026-09-23

### Added
- **A local settings script (`zsc-settings`) the installer drops next to the plugin, so every knob can be tuned without editing `~/.zshrc`.** The installer now creates `${XDG_CONFIG_HOME:-$HOME/.config}/zsh-smart-complete/settings.zsh` and symlinks `bin/zsc-settings` into `~/.local/bin/zsc-settings`. The plugin sources that file **before** its built-in defaults, so any `KEY='VALUE'` line written there overrides the default. `zsc-settings` exposes `wizard` / `list` / `get KEY` / `set KEY VALUE` / `edit` / `reset [KEY]` / `path` / `init`; `set` validates the value against the setting's type (bool / int / enum / path) and rejects bad input. A change takes effect after restarting zsh. Point `SMART_USER_CONFIG` at another file to override the location.

### Changed
- **The live completion popup is now autocomplete-like for paths and single matches.** A path (e.g. `/u`, `~/l`, `cd /usr/`) now lists candidates from the **first segment character**, and a bare `/` (or any trailing slash) lists the directory at once — the v2.2.9 rule waited for two segment characters, which made path completion feel dead. A **single** match now draws a 1-line popup (in addition to the inline ghost) instead of being ghost-only. Non-path words keep the two-character gate (`git s` stays silent until `git st`). Revert with `SMART_MENU_MIN_MATCHES=2` in your settings file.


## [v2.2.10] - 2026-09-22

### Fixed
- **Typing one character looked like it had submitted the line: every keystroke scrolled the terminal up by one row.** The display layer ended with `zle -R "" ""` "to force a redraw of the new region_highlight", and that form makes zsh rebuild its prompt area from scratch. Measured on the bytes zsh actually writes to a pty, one keystroke with a two-line prompt: **96 bytes including a `\r\r\n`** — a real newline, followed by a cursor-up move and a full-line erase — against **33 bytes without it**. The prompt sits on the last row of the terminal most of the time (any command output puts it there), and a newline on the last row scrolls the whole screen up by one row; the cursor-up that follows then lands on already-shifted content, which is what mixes the glyphs on the line being typed (`lls-la /etc/`). Each key therefore looked like it had been committed, with a fresh prompt printed underneath. With the ghost *and* the popup switched off the same keystroke cost 32 bytes, where stock zsh writes 1. The call is gone from both places it lived — `_smart_display_update` and the `→` accept path. The `region_highlight` array alone is enough: ZLE repaints once when the widget returns, and that repaint carries the ghost and its colour (verified: still `ESC[38;5;110m`).
- **The one redraw that is genuinely needed is now issued only when it is needed, instead of on every keystroke.** Removing the blanket call exposed what it had been doing incidentally: retiring candidate rows drawn for a longer prefix. While the list keeps being drawn zsh maintains that area itself — narrowing `git st` → `git sta` really does turn three rows into two — but the **last** transition, the tick where the listing is suppressed because the prefix narrowed to a single match, never reaches zsh's list code, so the old rows stayed sitting under the new ghost. The plugin now tracks whether rows of its own are still below the line and asks for the clearing redraw exactly once per collapse (new `_smart_menu_forget_rows`), including on the ticks that draw nothing by design — a closed gate and a throttled skip. Measured: the transition clears (0 stale rows under `git stat`, the same screen as before the fix) while an ordinary keystroke still costs 33 bytes, and 1 byte with both features off — exactly stock zsh.

### Added
- **`tests/test-repaint.zsh` — a regression test for the bytes zsh writes per keystroke.** The tmux end-to-end harness cannot see this class of bug at all: tmux undoes a newline-plus-cursor-up pair, so its screen *and* its scrollback come out identical whether or not the plugin redraws on every keypress. The test boots a real `zsh -i` through `zsh/zpty`, reads the raw byte stream with `zsh/mapfile` (a command substitution would strip the very trailing newline under test), and asserts one invariant on a two-line prompt: **one keystroke stays on one line** — no newline, no vertical cursor move, no screen erase — plus "with both channels off a keystroke costs its own echo and nothing else". It fails on the pre-fix code and passes here, so a future change that reinstates the redraw is caught by CI rather than by a user. `smart-menu status` now also reports whether candidate rows of ours are still on screen, the one piece of screen state the plugin keeps.

## [v2.2.9] - 2026-09-22

### Fixed
- **Seventeen control keys were dead, including Ctrl-A, Ctrl-E, Ctrl-K, Ctrl-L, Ctrl-R, Ctrl-U and Ctrl-W.** All printable characters are bound with two range binds (`bindkey -R "^@"-"^_"`, `-R " "-"~"`), and the first of those ranges *also* claims every control key: measured on zsh 5.9, `bindkey -M emacs '^A'` reported `self-insert` immediately after it, so Ctrl-A inserted a literal control character instead of jumping to the start of the line. Only the keys the plugin deliberately wraps (`^M`, `^Y`, `^_`, `^G`, `^I`) survived, because they are re-bound later. The original binding of every control key is now snapshotted per keymap **before** any of our binds run, and restored right after the range bind, so Ctrl-A/E/F/K/L/N/P/R/T/U/W/V/X (and the rest of `^A`-`^_`) behave exactly as the user configured them; the keys we do wrap are then re-taken by the wrapper binds below.
- **`SMART_SUGGEST_STRATEGY=history,completion` never produced a completion suggestion — and it is now the default.** The probe behind it was called as `$( _smart_menu_completion_suffix )`, i.e. inside a command substitution: `$()` forks a subshell, where the `zle` builtin cannot run, so the probe silently returned nothing, `after == before` on every keystroke, and the completion half of the strategy was dead for every user since the day it shipped. The default is now `history,completion` because history alone leaves a hint vacuum exactly where a hint is expected: typing `cd /u` matches a single filesystem candidate, so the type-to-popup list stays suppressed by `SMART_MENU_MIN_MATCHES=2`, and if `cd /usr/...` was never run there is no history match either — nothing on screen at all. A widget-context worker `_smart_menu_probe_suffix` now returns through a global instead of stdout and is called directly; the printing wrapper stays for tests and manual debugging, with a comment saying why it must never be used inside `$()`. `SMART_SUGGEST_STRATEGY=history` restores the history-only behaviour.
- **The inline grey suggestion was hard to tell apart from text you had actually typed, so a one-letter prefix looked like the whole command had already been entered.** The suggestion is painted with `region_highlight` using `SMART_SUGGEST_COLOR`, which defaulted to `fg=8` (bright black) — on many themes, and on the default Ubuntu / WSL palette, that is nearly the same shade as the normal foreground, so `l` followed by a dim `s -la /usr/` reads as if `ls -la /usr/` were already on the line. Nothing is inserted into the buffer: pressing Enter on `l` runs `l`. The default is now `auto`, which resolves to `fg=110` (a clearly dimmer blue-grey) on 256-colour terminals — detected through `terminfo[colors]`, with `TERM` as a fallback (`*256color*`, `*truecolor*`, and known 256-colour terminals such as kitty / Alacritty / WezTerm / iTerm2 / GNOME / Konsole / foot) — and keeps `fg=8` on true 8/16-colour terminals, which have no colour 110. An explicit value (`SMART_SUGGEST_COLOR="fg=245,bold"`) is still honoured verbatim.
- **The candidate list opened after a single keystroke, and the minimum counted the whole path instead of the part you were typing.** `SMART_MENU_MIN_PREFIX` (and its command-word twin `SMART_MENU_MIN_PREFIX_CMD`) defaulted to `1`, so pressing `l` drew a full list of every matching command and history entry before you had typed anything meaningful; with `/etc/l` the count was six, because the gate measured the entire shell word, so the list also appeared right after the `/`. Both keys now default to `2` and count only the **last segment after the final `/`** — `/etc/l` counts as one typed character, `/etc/lo` opens the list. The upper bound `SMART_MENU_MAX_PREFIX` still measures the whole word. Note: once drawn, a list is ordinary terminal output that zsh never erases (stock zsh behaves identically), so drawing fewer lists is the only lever — an erase-after-draw attempt was implemented, measured, and removed.
- **Starship kept rendering its own default prompt instead of the recommended two-line layout.** When the installer runs from `curl ... | bash` there is no `templates/` directory, so the config came from a second, inline copy — and that copy was missing the `format =` line. Without `format`, starship silently ignores the rest of the file and prints its own default (`hostname in ~ via 🐍 ... ❯`), which is exactly what a fresh v2.2.8 install showed. The fallback copy is now byte-identical to `templates/starship.toml.example` (single canonical writer, pinned by installer test section 21), and an existing `starship.toml` is now classified: **recommended** (has both the `success_symbol = "[:> ](bold green)"` marker and a `format` key) is left alone; **legacy** (written by an earlier version, no `format` key) is repaired automatically with a `~/.config/starship.toml.bak.<timestamp>` backup and no prompt; **custom** still asks first.
- **Installer output that was still hardcoded in English.** The remaining blocks — package-manager messages, the zsh / Oh-My-Zsh / atuin / fzf / starship / Entware sections, cleanup, backup, powerlevel10k, `.zshrc` and the combo snippet — now go through the i18n table in all five languages: `install.sh` carries 234 keys and `install-entware.sh` 150, with zero hardcoded output strings, zero keys that render empty, and every referenced key actually defined — five such keys (`i.fzf_not_in_feed` in the main installer, plus `w.omz_failed`, `w.zsh_theme_write_failed`, `s.zsh_theme_set`, `s.zsh_theme_appended` in the Entware installer) had no definition at all and printed their raw key name (installer test section 22).

## [v2.2.8] - 2026-09-21

### Fixed
- **The installer's language-selection menu showed every option in English, so a user who does not read English could not pick their own language.** `select_language` rendered the five options through `msg lang.option_*`, which follows `LANG_CODE` and falls back to English at the default (`en`); the whole menu became English. The menu now always prints each language in its own script (endonym): `English / 简体中文 / 繁體中文 / 日本語 / 한국어`, so every reader recognises their entry without knowing English. The dead `lang.option_*` keys were removed so `install.sh` and `install-entware.sh` carry identical i18n tables and menus; the parity is pinned by a new installer test (section 18).

## [v2.2.7] - 2026-09-19

### Fixed
- **Two dynamic hints on screen at once, even with every installer answer at its default: the plugin's popup plus atuin's own floating search TUI.** The recommended config used to run `eval "$(atuin init zsh --disable-up-arrow)"` unconditionally whenever the `atuin` binary existed. That only unbinds the Up arrow: atuin still binds **Ctrl-R** and, in current releases, **`?`** (Atuin AI) — and its TUI is a second full-screen UI (floating list of every matching history entry, duplicates included, Enter accepts) right next to the plugin's popup. Since the plugin reads atuin's SQLite history database directly for the grey suggestion, the bindings bought nothing. The generated config now writes `ATUIN_NOBIND="true" eval "$(atuin init zsh)"`: history recording and the plugin's atuin backend are untouched, but ↑ / Ctrl-R / ? stay native and the screen keeps a single UI. Binding atuin's TUI is now an explicit installer question (default: no, asked in all five languages), and the atuin init line moved out of the combo snippet into the integration block, so atuin recording now works in every combo (previously the Oh-My-Zsh / p10k combos silently had none). The shipped `templates/zshrc.example` follows the same rule. New read-only advisory `_scan_foreign_atuin` reports `atuin init` lines found OUTSIDE the plugin's managed block (e.g. a line from an earlier manual setup), which would otherwise silently resurrect the second UI.

## [v2.2.6] - 2026-09-19

### Fixed
- **The inline grey suggestion lost its colour, and every keystroke left a zombie highlight entry behind.** Two defects in the plugin's `region_highlight` handling, both proven with a colour-aware tmux probe. 1) The marker identifying our entry was a `#comment` token — and zsh drops comment text from `region_highlight` on every redraw — so the filter that removes our previous entry stopped matching and stale entries piled up with each keystroke (measured: 5 keystrokes -> 8 entries; 171 with fast-syntax-highlighting loaded). The marker is now a `memo=` token, which zsh preserves verbatim. 2) Drawing a candidate list makes zsh re-render the line and clip any highlight entry reaching into POSTDISPLAY back to the end of BUFFER (zero length = no colour). The plugin now re-asserts the entry right after every list draw — no extra redraw, the list stays on screen. Verified against both zsh-syntax-highlighting and fast-syntax-highlighting: they coexist correctly and no compatibility hook is needed — the earlier "F-Sy-H clears foreign entries" conclusion was wrong.
- **`bash -c "$(curl -fsSL .../install.sh)"` failed with `argument list too long: bash`.** install.sh has outgrown Linux's 128 KiB per-argument limit (`MAX_ARG_STRLEN`). All documents now use the pipe form `curl -fsSL .../install.sh | bash` (mirror form: `curl -fsSL .../install.sh | SMART_INSTALL_GH_MIRROR=... bash`), which never passes the script through argv.
- **Installer prompts did not wait for input when the script was piped** (`curl ... | bash`): stdin *is* the script, so every plain `read` returned empty immediately and the language / proxy / mirror menus silently took their defaults. All interactive reads now go through a `_tty_read` helper that re-opens `/dev/tty`. `BASH_SOURCE[0]` is guarded too — it is unset when the script arrives on stdin (under `set -u` the script aborted; otherwise `SCRIPT_DIR` silently became the caller's cwd).
- **Starship parse error `Error parsing "format": --> 1:7` on `[$user] › $directory`.** Two mistakes compounded: a top-level `[text]` group in starship requires a `(style)` suffix, and the top-level variable is `$username` (`$user` only exists inside the `[username]` module). The template now reads `$username › $directory`, and both copies (the example template and the Entware installer's inline one) are pinned by a regression test that renders the config with a real `starship` binary.

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
