# lib/config.zsh
#
# Configuration layer.
#
# All user-facing knobs use the SMART_ prefix. Values are set with
# `: ${VAR:=default}` so a user can export them *before* sourcing the plugin
# and their values are respected. No value set in this file ever overrides
# one that the user has already set.
#
# The config module NEVER reads from state, history, display or event.
# It is the leaf that everything else depends on.

emulate -L zsh
setopt extended_glob no_warn_create_global

# ---------------------------------------------------------------------------
# Master switch
# ---------------------------------------------------------------------------
# If false, we still source everything but do not install widgets, and the
# suggestion engine never runs. The user can flip this later with
# `smart-enable` / `smart-disable`.
: ${SMART_ENABLED:=true}

# ---------------------------------------------------------------------------
# Engine toggles
# ---------------------------------------------------------------------------
: ${SMART_SUGGEST:=true}           # compute inline suggestions
: ${SMART_COMPLETE:=true}          # participate in Tab completion

# Where the inline (grey) suggestion comes from. Comma-separated, tried in
# order; the first one that yields something wins.
#
#   history     = the best prefix match from your history (ranked + scored by
#                 lib/engine/ranking.zsh). Cheap, and the reason this plugin
#                 exists.  <-- default
#   completion  = the completion system's unambiguous prefix for the current
#                 word (what Tab would insert before it needed to choose).
#                 Lets the ghost suggest paths, options and subcommands that
#                 are NOT in your history. Costs one extra completion run on
#                 each keystroke that history could not answer, so it is
#                 opt-in: SMART_SUGGEST_STRATEGY=history,completion
#
# The same names as zsh-autosuggestions' ZSH_AUTOSUGGEST_STRATEGY, so muscle
# memory transfers.
: ${SMART_SUGGEST_STRATEGY:=history}

# ---------------------------------------------------------------------------
# History backend
# ---------------------------------------------------------------------------
# One of: zsh | atuin | smart-engine (future)
#
# "zsh"    = build an in-memory index from `fc -ln -r` (default, no deps).
# "atuin"  = use `atuin search --search-mode prefix` if the binary is on
#            PATH; fall back to zsh silently if it's not.
# "smart-engine" = reserved for a future IPC backend.
: ${SMART_HISTORY_BACKEND:=zsh}

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
: ${SMART_INLINE:=true}            # render inline suggestion via region_highlight
: ${SMART_SUGGEST_MAX:=1}          # how many suggestions to keep (future menu)
: ${SMART_SUGGEST_HISTORY_LIMIT:=20000}  # how many recent fc lines to index
: ${SMART_HISTORY_REBUILD_EVERY:=500}    # auto-rebuild after N new cmds (0=never)

# Inline suggestion color. Defaults to dim grey (color 8) which works in both
# 16-color dark and light terminals. Users can override with any valid
# region_highlight spec, e.g. "fg=245" or "fg=cyan,bold".
: ${SMART_SUGGEST_COLOR:=fg=8}

# ---------------------------------------------------------------------------
# Keymap scope
# ---------------------------------------------------------------------------
# Bind in emacs keymap, viins keymap, or both.
# "both" is the default: every sane shell user deserves suggestions.
: ${SMART_KEYMAP_SCOPE:=both}      # both | emacs | viins

# ---------------------------------------------------------------------------
# Native completion UI
# ---------------------------------------------------------------------------
# Menu-select style: when user presses Tab and there are multiple candidates,
# Zsh pops up a highlightable menu. Set to false to keep the default
# list-then-complete behavior.
: ${SMART_NATIVE_MENU_SELECT:=true}

# Whether to install list-colors for completion candidates.
: ${SMART_NATIVE_LIST_COLORS:=true}

# ---------------------------------------------------------------------------
# Type-to-popup candidate menu (the zsh-autocomplete half)
# ---------------------------------------------------------------------------
# When true, the candidate list is computed and drawn on EVERY buffer edit —
# you see completions appear while you type, without pressing Tab. When the
# prefix narrows to a single candidate the list is dropped and the inline
# (grey) suggestion takes over. This is what makes zsh-autocomplete +
# zsh-autosuggestions unnecessary: one plugin, two non-conflicting channels.
#
# Turn it off with SMART_MENU=false, or at runtime with `smart-menu off`.
: ${SMART_MENU:=true}

# Minimum characters before we list, for an ARGUMENT word (after the command).
# 1 = list as soon as the first character is typed. 0 = also list on an empty
# word (i.e. immediately after a space) — this mirrors zsh-autocomplete but
# dumps every candidate, so 1 is the default.
: ${SMART_MENU_MIN_PREFIX:=1}

# Minimum characters before we list the COMMAND word (the first word of the
# line). 2, because one letter matches thousands of binaries.
: ${SMART_MENU_MIN_PREFIX_CMD:=2}

# Do not draw a list for fewer than this many candidates — a lone candidate is
# already shown as inline ghost text, and a one-line list is just noise.
: ${SMART_MENU_MIN_MATCHES:=2}

# Upper bound on the word length we bother completing (long words have almost
# no matches; this keeps the per-keystroke cost bounded).
: ${SMART_MENU_MAX_PREFIX:=64}

# Hard ceiling on candidates shown by the live popup. When a word has more
# matches than this, the popup is *suppressed* entirely instead of drawn.
#
# This is what keeps the live popup from (a) re-rendering thousands of rows on
# every keystroke and (b) tripping zsh's interactive
# "do you wish to see all N possibilities (M lines)?" confirmation. zsh gates
# that confirmation on LISTMAX, and the popup deliberately does NOT touch
# LISTMAX: setting it around a `zle` listing call corrupts ZLE's next input
# read and silently EATS ONE KEYSTROKE (measured: `git status` typed into the
# popup arrives as `gitstatus`, and the shell then runs the wrong command).
# Capping the list is the fix that is both correct and fast. zsh/complist is
# still loaded so any list that *is* drawn stays scrollable.
#
# 0 = uncapped (not recommended: an unbounded live list is where both the
# re-render cost and the prompt problem come from).
: ${SMART_MENU_MAX_MATCHES:=100}

# Single-column (vertical) layout for the live type-to-popup.
# OPT-IN: default OFF, and that default is deliberate.
#
# When true, candidates are drawn ONE PER LINE (a vertical list below the line)
# instead of zsh's native multi-column grid.
#
# Why off by default: a vertical list is only possible by GENERATING the
# candidates ourselves (there is no reliable way to capture compsys' own — see
# below), and generating them has real costs. Read these before enabling it:
#
#   * This branch never calls `_main_complete`, so for the contexts it covers
#     you lose the candidate DESCRIPTIONS, `list-colors` colouring, grouping,
#     and your `zstyle ':completion:*' matcher-list` (so the fuzzy matching
#     documented for the popup does NOT apply to generated candidates).
#   * Only commands / functions / aliases / builtins, filesystem paths and
#     `cd` recent-directories are generated. Every other context (git
#     subcommands, ssh hosts, `--options`, `sudo …`, `~user`) produces nothing
#     here and FALLS THROUGH to the native grid — so the popup changes shape
#     while you type, which reads as "a second box appeared".
#   * A candidate wider than the terminal is clipped to one line (no ellipsis).
#
# Why generated rather than captured: shadowing zsh's `compadd` with a function
# makes several zsh builds stop adding matches altogether (measured), so there
# is no reliable way to capture the real candidate list and still draw it.
: ${SMART_MENU_SINGLE_COLUMN:=false}

# ---------------------------------------------------------------------------
# WHICH LISTER OWNS THE SCREEN
# ---------------------------------------------------------------------------
# Two completion listers loaded at once is the classic "why are there two boxes
# on my screen?" report, and no amount of tuning fixes it: both are drawing, and
# both are entitled to. This picks ONE owner.
#
#   builtin   (default) — zsh's own renderer, driven by this plugin.
#   fzf-tab             — this plugin stops drawing its list entirely and hands
#                         the screen to the external floating picker.
#
# `fzf-tab` does NOT load fzf-tab (that is a plugin you install yourself); it
# makes US stop listing, so the other lister is the only one drawing. Use it
# when you run fzf-tab — or any other floating picker — and see two lists.
#
# The inline grey suggestion (the autosuggestions half of this plugin) is NOT
# affected: only the candidate list is handed over. With `fzf-tab` we also stop
# setting `zstyle ':completion:*' menu select` in the Tab widget, because zsh's
# selectable menu is itself a list drawer competing for the same screen. Tab's
# own cycling behaviour is deliberately left alone — this switch is about the
# list, not about Tab.
#
# Runtime: `smart-lister` prints it, `smart-lister builtin|fzf-tab` changes it
# for the current shell. `smart-doctor` reports whether the other lister is
# actually loaded, and warns when you picked `fzf-tab` while nothing else is
# present — that combination would otherwise present as "the popup vanished".
: ${SMART_MENU_LISTER:=builtin}

# Prefix-search history on ↑ / ↓ while the popup is enabled (opt-in).
#
# false (default) = ↑ / ↓ keep their native behaviour (plain history
#                   navigation). Turning this on silently changes a key most
#                   people have hard muscle memory for, so it is not the
#                   default.
# true          = with a NON-EMPTY line, ↑ / ↓ walk the history entries that
#                   start with what you typed (zsh's own
#                   history-beginning-search-backward/forward). With an empty
#                   line they fall through to plain history navigation, so you
#                   never lose the ability to scroll history.
: ${SMART_MENU_HISTORY_KEYS:=false}

# Adaptive throttle. A listing that takes at least this many milliseconds buys a
# cool-down, so typing stays responsive in genuinely expensive completion
# contexts (huge directory listings, completions that shell out).
#
# Default: OFF (SMART_MENU_COOLDOWN_KEYS=0). Measured on a real session: every
# ordinary listing costs 10-30ms, and the only spike is a ONE-OFF ~180ms the
# first time a completion subsystem is loaded (e.g. the first `git <TAB>`).
# Throttling that spike is exactly wrong: it suppresses the popup on the very
# first command you type and saves 180ms once. Since a skipped edit also drops
# the list that was on screen, the cooldown is only worth enabling when you have
# a completion that is persistently expensive — then set SMART_MENU_SLOW_MS to
# just under its cost and SMART_MENU_COOLDOWN_KEYS to 1 or 2.
: ${SMART_MENU_SLOW_MS:=250}

# How many edits to skip listing after a slow one. 0 = never skip, so the popup
# always matches what you typed. 1 is the recommended value if you do enable it:
# every skipped edit is an edit whose candidates are not shown.
: ${SMART_MENU_COOLDOWN_KEYS:=0}

# Optional decision trace — set to a file path to log every tick decision
# (gate refusal, cooldown skip, match count, cost). The on-screen result cannot
# tell you *why* a popup is missing; this can.
: ${SMART_MENU_DEBUG:=}

# ---------------------------------------------------------------------------
# Recent directories in the completion menu ("recent-paths")
# ---------------------------------------------------------------------------
# When true, the directories you have cd'd into are offered as candidates while
# you complete a `cd` / `pushd` / `chdir` argument — and, because that is the
# one place where such a list is actually what you want, the popup also opens
# on the EMPTY word right after `cd ` (every other empty word still follows
# SMART_MENU_MIN_PREFIX and shows nothing).
#
# The data is zsh's own recent-directories database — the same one `cdr` and
# `~[<n>]` use. We only READ it: if you have never enabled collection there is
# simply nothing to show. Two lines turn it on (see README):
#
#     autoload -Uz chpwd_recent_dirs add-zsh-hook
#     add-zsh-hook chpwd chpwd_recent_dirs
#
# Implementation note: this works by prepending a completer to
# `zstyle ':completion:*' completer`, so it runs before `_complete` (which would
# otherwise end the chain before our turn). It never replaces anything —
# candidates are added and the chain continues. `smart-recent off` restores the
# zstyle exactly as it was found (including removing it, if you had not set one).
#
# Do NOT be tempted to append to a `$completer` array: no such variable exists.
# `_main_complete` reads the chain from the zstyle above and falls back to
# `_complete _ignored` when it is unset, so writing `$completer` looks wired up
# and silently does nothing.
: ${SMART_RECENT_PATHS:=true}

# Upper bound on how many recent directories are offered. 0 = no limit.
: ${SMART_RECENT_PATHS_MAX:=20}

# ---------------------------------------------------------------------------
# Ranking algorithm (v0.1.3)
# ---------------------------------------------------------------------------
# Exponential time decay: recency_score = 1000000 / (1000 + alpha * rec)
# Higher alpha = faster decay. Default 10 (≈0.01 in float terms).
# With 20000-entry index: rec=0→1000, rec=500→167, rec=2000→48.
: ${SMART_RANKING_DECAY_ALPHA:=10}

# CWD relevance boost (milli-units, 1000=1.0x):
# When a command was last executed in the current $PWD, its final score
# is multiplied by this value. Default 1500 (1.5x boost).
# 1000 = no boost, 2000 = 2x boost.
: ${SMART_RANKING_CWD_BOOST:=1500}

# ---------------------------------------------------------------------------
# Atuin backend (v0.2.0)
# ---------------------------------------------------------------------------
# Path to the Atuin SQLite database. Falls back to $HOME/.local/share/atuin/history.db.
# If the file does not exist or `sqlite3` binary is missing, the plugin falls
# back to the zsh backend silently.
: ${SMART_ATUIN_DB_PATH:="${HOME}/.local/share/atuin/history.db"}

# Same-host boost (milli-units, 1000=1.0x):
# Atuin stores which hostname each command was run on. If a command came from
# the current host, apply this multiplier on top of the base score.
# Default 1300 = 1.3x boost.
: ${SMART_ATUIN_HOST_BOOST:=1300}

# Failed-exit penalty (milli-units, 1000=1.0x):
# If a command's Atuin record has exit != 0, multiply its score by this value.
# Default 500 = 0.5x (penalise half).
: ${SMART_ATUIN_FAILED_PENALTY:=500}

# If true, drop any Atuin records with exit != 0 entirely. Default false.
: ${SMART_ATUIN_SUCCESS_ONLY:=false}
