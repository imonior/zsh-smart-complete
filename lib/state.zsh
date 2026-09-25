# lib/state.zsh
#
# Central state container.
#
# RULE: mutable RUNTIME STATE that crosses module boundaries lives in one of the
# arrays below, addressed by one of the accessors at the end of this file. A
# module that needs such a value adds a key here instead of inventing a scalar.
#
# The rule used to be stated as "every piece of mutable, cross-module runtime
# data lives here, and you will never see a standalone `_smart_thing=foo`
# anywhere else in this codebase". That was never true: dozens of globals are
# declared outside this file (`tools/check-module-globals.sh --list` prints the
# current set). The count was not the problem, the missing boundary was — so the
# boundary is now stated where it can be checked:
#
#   tools/check-module-globals.sh  compares every global declaration in lib/
#   against the register at the bottom of this file, and CI runs it through
#   tests/test-module-globals.sh. A new global therefore needs a reason.
#
# What belongs here is decided by LIFECYCLE, not by tidiness:
#   * The container is rebuilt from nothing by _smart_history_rebuild, and
#     _smart_state_reset() empties all three arrays. Anything stored here must be
#     meaningless until something refills it and safe to lose on a reset.
#   * Four kinds of global fail that test, and moving them here would COST
#     something rather than rearrange furniture:
#       - binding snapshots: the widget a key called before we wrapped it, read
#         on every keystroke. lib/state.zsh is sourced BEFORE lib/event/zle.zsh
#         (see the loader), so a reset after the capture would delete data that
#         only the user's keymaps can supply.
#       - out-parameters: the slot a callback fills when its caller cannot take
#         a return value. Those are a function signature drawn in the only
#         namespace zsh gives a by-reference write, not state.
#       - constants and key tables.
#       - probes with a documented lifetime of one rebuild or one shell.
#
# Why keep a container at all, if half the data stays out of it?
#   * It is trivial to dump / snapshot / reset for debugging, and the history
#     index is the one part that genuinely needs all three.
#   * It maps 1:1 onto a future struct SmartState in the independent shell.
#   * It prevents the "37 unrelated global scalars" rot that kills every
#     zsh plugin past 1000 LoC. The register is what stops that number from
#     silently becoming 51 unrelated globals again.

emulate -L zsh
setopt extended_glob no_warn_create_global

# ---------------------------------------------------------------------------
# State arrays
# ---------------------------------------------------------------------------
# _SMART_STATE    = scalar slots (strings, numbers, booleans-as-"0"/"1")
# _SMART_STATE_A  = associative sub-maps (history freq, history recency, …)
# _SMART_STATE_L  = list slots (ordered history entries, active keymaps…)

typeset -gA _SMART_STATE
typeset -gA _SMART_STATE_A
typeset -gA _SMART_STATE_L

# Fast in-memory history index (mirrors history.cmds — no string round-trip).
#   _SMART_CMDS        indexed array, distinct commands (membership only:
#                      fresh from a rebuild they are newest-first, but
#                      incremental inserts just append — recency ORDER is
#                      carried by _SMART_CMDS_FIRST)
#   _SMART_CMDS_FIRST  assoc: first-char -> newline-joined commands, kept in
#                      recency order (newest first) by the history layer
# Both are (re)built by _smart_state_l_set (history.cmds) so prefix iteration
# is O(bucket) instead of O(n) split + linear scan per keystroke.
typeset -ga _SMART_CMDS=()
typeset -gA _SMART_CMDS_FIRST=()

# Canonical keys in _SMART_STATE (documented for future porting to Rust):
#
#   enabled                "1" / "0"          -- master runtime toggle
#   buffer                 string             -- last-seen BUFFER copy (for
#                                                change detection)
#   cursor                 number             -- last-seen CURSOR copy
#   suggestion.text        string             -- current inline suggestion
#   suggestion.source      "history|completion" -- where it came from ("" = none)
#   suggestion.score       "0.000"-like       -- fixed-point score
#   history.count          number             -- distinct commands indexed
#   history.rebuilt_at     epoch seconds      -- last index rebuild
#   history.new_since      number             -- new commands since rebuild
#   history.max_freq       number             -- for ranking normalisation
#   history.max_recency    number             -- upper bound on any age
#   history.tick           number             -- monotonic last-use counter
#
# The three list-like shapes below are not free-form: a key that no code uses
# here was twice as misleading as useful (this doc once named `history.freq` for
# a map called `history.frequency`, and a `history.first_char` that was written
# by nothing after _SMART_CMDS_FIRST superseded it), so check-module-globals.sh
# now fails a documented key that has no writer or reader in lib/.

# Canonical sub-maps in _SMART_STATE_A (addressed as "<submap>|<key>"):
#   history.frequency      cmd -> occurrence count
#   history.recency        cmd -> last-use tick (see history.max_recency;
#                          age = tick - stored, 0 = just used)
#   history.cwd            cmd -> directory it last ran in
#   history.host           cmd -> host it last ran on
#   history.exit           cmd -> its last exit status

# Canonical lists in _SMART_STATE_L:
#   history.cmds           distinct commands; recency ORDER lives in the
#                          first-char buckets (see _SMART_CMDS_FIRST)

# ---------------------------------------------------------------------------
# Accessors
# ---------------------------------------------------------------------------
# Write through these helpers so validation, logging and a future key migration
# all have one place to happen.
#
# READING ON THE KEYSTROKE PATH IS THE EXCEPTION, AND IT IS FORK-SHAPED: these
# helpers `print`, so using them means a command substitution, so ~0.4 ms per
# call (the same cost that moved _smart_menu_now_ms off its printing form). A
# hot reader therefore subscripts the array directly:
#
#     local text="${_SMART_STATE[suggestion.text]}"
#
# Measured per read against a plain global, 300k iterations, zsh 5.9 / arm64:
#   plain global scalar            ~0.2 us
#   _SMART_STATE, literal key      ~0.6 us
#   _SMART_STATE, key in variable  ~0.8 us
#   $(_smart_state_get …)          ~400 us  <- the only number worth avoiding
#
# So a subscript is never a good excuse to add a module global (it costs less
# than a microsecond), and never a reason not to read one directly either. Keys
# containing `|` must be built in a variable first: assoc["a|b"]=x stores the
# quotes as part of the key, which makes the entry unreachable by assoc[a|b].

_smart_state_get() {
    local key="$1" default="${2:-}"
    local v="${_SMART_STATE[$key]}"
    if [[ -z "$v" ]]; then
        print -r -- "$default"
    else
        print -r -- "$v"
    fi
}

_smart_state_set() {
    local key="$1" value="$2"
    [[ -z "$key" ]] && return 1
    _SMART_STATE[$key]="$value"
    return 0
}

_smart_state_unset() {
    local key="$1"
    unset "_SMART_STATE[$key]" 2>/dev/null
    return 0
}

# _smart_state_a_get <submap> <key> [default]
_smart_state_a_get() {
    local sub="$1" key="$2" default="${3:-}"
    local compound="${sub}|${key}"
    local v="${_SMART_STATE_A[$compound]}"
    if [[ -z "$v" ]]; then
        print -r -- "$default"
    else
        print -r -- "$v"
    fi
}

_smart_state_a_set() {
    local sub="$1" key="$2" value="$3"
    [[ -z "$sub" || -z "$key" ]] && return 1
    local compound="${sub}|${key}"
    _SMART_STATE_A[$compound]="$value"
    return 0
}

_smart_state_a_unset_sub() {
    local sub="$1"
    local k
    for k in "${(@k)_SMART_STATE_A}"; do
        [[ "$k" == "${sub}|"* ]] && unset "_SMART_STATE_A[$k]"
    done
    return 0
}

# _smart_state_l_get <list> -- echo one element per line (read only $())
_smart_state_l_get() {
    local sub="$1"
    local existing="${_SMART_STATE_L[$sub]}"
    if [[ -z "$existing" ]]; then
        return 0
    fi
    # Stored newline-joined (see _smart_state_l_set), so the value already IS
    # one element per line: print it as-is, no tr, no fork.
    print -r -- "$existing"
    return 0
}

# _smart_state_l_set <list> <args..> -- replace the whole list.
# Call directly (no $() subshell) so the write persists.
#
# INVARIANT: entries are newline-free. They are history command lines, and the
# bucket map (_SMART_CMDS_FIRST) already stores them newline-joined, so an
# embedded newline would corrupt it long before this store noticed. That is why
# the list can share the same separator: ${(F)...} joins in one C-level pass,
# while building the string with `joined+=$'\x1f'$v` per entry re-copies the
# whole accumulator and turns a 20k-entry rebuild into ~10 s of memcpy.
_smart_state_l_set() {
    local sub="$1"; shift
    if [[ "$sub" == "history.cmds" ]]; then
        # Mirror into fast structures for O(bucket) prefix iteration.
        _SMART_CMDS=("$@")
        _smart_cmds_rebucket
    fi
    _SMART_STATE_L[$sub]="${(F)@}"
    return 0
}

# _smart_cmds_rebucket -- rebuild _SMART_CMDS_FIRST from _SMART_CMDS.
#
# Called at the end of every history rebuild, with the whole index (up to
# SMART_SUGGEST_HISTORY_LIMIT entries) in hand, so its cost is paid on the
# user's Enter. Two zsh-level per-element operations are quadratic here and
# both were measured:
#   * `bucket+=$'\n'$cmd` re-copies the accumulator per command;
#   * building a tag array with `tags+=…` and then reading `_SMART_CMDS[idx]`
#     back out — zsh arrays are linked lists, so appending past the chunk
#     table and subscripting an arbitrary position each walk the elements,
#     making an element-at-a-time build ~1 s at 32k entries.
# The projection below keeps those walks out of zsh: ${(M)a:#pat} filters and
# ${(F)a} joins run at C speed, so the only per-element zsh work is reading one
# character to discover the bucket keys. Same 32k entries: ~85 ms, linear.
#
# Order inside a bucket is the array's order, which is what
# _smart_history_iter_prefix relies on for recency.
_smart_cmds_rebucket() {
    emulate -L zsh
    local -A seen=()
    local c k
    for c in "${_SMART_CMDS[@]}"; do
        [[ -n "$c" ]] && seen[${c[1]}]=1
    done
    _SMART_CMDS_FIRST=()
    for k in "${(@k)seen}"; do
        # The `@` flag is what keeps this an array filter — without it the
        # expansion is scalar and nothing is removed. The key is substituted,
        # not written into the pattern, so zsh matches it literally: a bucket
        # keyed `*` holds only commands that start with an asterisk (checked
        # against #, *, ?, [, <, ^, ~, |, &, (, ), $, backtick and backslash).
        _SMART_CMDS_FIRST[$k]="${(F)${(M@)_SMART_CMDS:#${k}*}}"
    done
    return 0
}

# ---------------------------------------------------------------------------
# Full reset
#
# Called once when this file is sourced (see the bottom) and by the test
# suites that need a known-empty container. NOT on a rebuild:
# _smart_history_rebuild clears exactly the history slots it is about to
# refill, because a reset here would also drop `enabled`, `buffer` and the
# cursor bookkeeping that the wrapper widgets compare against.
# ---------------------------------------------------------------------------
_smart_state_reset() {
    _SMART_STATE=()
    _SMART_STATE_A=()
    _SMART_STATE_L=()
    # Sensible zero values that every caller expects to exist.
    _smart_state_set enabled 1
    _smart_state_set buffer ""
    _smart_state_set cursor 0
    _smart_state_set suggestion.text ""
    _smart_state_set suggestion.source ""
    _smart_state_set suggestion.score ""
    _smart_state_set history.count 0
    _smart_state_set history.rebuilt_at 0
    _smart_state_set history.new_since 0
    _smart_state_set history.max_freq 0
    _smart_state_set history.max_recency 0
    _smart_state_set history.tick 0
    _SMART_CMDS=()
    _SMART_CMDS_FIRST=()
    return 0
}

# Initialise on first load.
_smart_state_reset

# ---------------------------------------------------------------------------
# Register: every _SMART_* global that lives OUTSIDE this container
# ---------------------------------------------------------------------------
# Format, read by tools/check-module-globals.sh:
#
#     # GLOBAL: <name-or-glob>  <why it stays a global>
#
# One entry per line; the reason is set off by TWO spaces (that is how the
# parser knows where the name ends, and a single space reports as "no reason").
# The check runs both ways — an unregistered global fails, and so does an entry
# that matches nothing — so this is a contract rather than a snapshot: adding a
# global means saying here why it is not state, and moving one into the
# container means deleting its line.
#
# Grouping is by LIFECYCLE, which is the question the container asks. Several of
# the groups below are out-parameters: a caller that cannot take a return value
# still has to put it somewhere, and the container is the wrong place for a
# value whose whole life is one function call. Cost is not the argument
# anywhere: a direct subscript reads in well under a microsecond (see "READING
# ON THE KEYSTROKE PATH" above), so this register argues lifetime, never speed.

# The container itself.
# GLOBAL: _SMART_STATE  scalar slots, one string each
# GLOBAL: _SMART_STATE_A  associative sub-maps, addressed as "sub|key"
# GLOBAL: _SMART_STATE_L  list slots, stored newline-joined
# GLOBAL: _SMART_CMDS  mirror of history.cmds, rebuilt and cleared with it
# GLOBAL: _SMART_CMDS_FIRST  its first-char buckets, so a prefix read takes a
#   bucket instead of splitting a string

# Binding snapshots, in three shapes. Captured from the USER's keymaps once per
# shell, then read on every wrapped keystroke. This file is sourced before
# lib/event/zle.zsh, so a reset here would delete what nothing but the user's
# own config can supply again.
# GLOBAL: _SMART_EVT_ORIG_*  widget behind a wrapped key, per keymap
# GLOBAL: _SMART_NATIVE_ORIG_TAB_*  widget behind Tab, per keymap
# GLOBAL: _SMART_EVT_SAVED  same for the multi-sequence keys, "<keymap>|<seq>"

# Key tables: every byte sequence one logical key can arrive as, derived from
# terminfo plus the two fallbacks (see the multi-sequence note in
# lib/event/zle.zsh). Constant for the life of the shell.
# GLOBAL: _SMART_EVT_*_SEQS  terminal key encodings, built once

# Sentinel for "the capture above has run in this shell". Deliberately not
# derived from the values it guards: a stale one must not skip the capture.
# GLOBAL: _SMART_EVT_CAPTURED  one capture per shell

# A CONSTANT, not state: the region_highlight memo that marks the ghost as ours.
# GLOBAL: _SMART_RH_MARKER  fixed marker string, never written again

# Out-parameters for the history backends (lib/history/zsh.zsh,
# lib/history/atuin.zsh): pluggable, so the rebuild cannot take their result as
# a return value. Opened and `unset` inside one rebuild, and moving 20k+
# commands through a string-keyed map would re-add the round-trip _SMART_CMDS
# exists to avoid.
# GLOBAL: _SMART_BUILD_*  backend out-param, one rebuild wide

# Out-parameters again. The `_scan` halves of printing functions, kept because
# wrapping them in $() costs a fork on the keystroke path (~0.4 ms), plus the
# candidate rows one menu function fills for the next one.
# GLOBAL: _SMART_SCORE_RET  fork-free return for the scoring helpers
# GLOBAL: _SMART_PROBE_SUFFIX_RET  fork-free return for the completion probe
# GLOBAL: _SMART_MENU_LISTER_RET  fork-free return for the lister decision
# GLOBAL: _SMART_MENU_NOW_MS  fork-free return for the clock read
# GLOBAL: _SMART_MENU_CAND  candidate rows, generator -> lister
# GLOBAL: _SMART_MENU_DISP  their padded display strings
# The per-compute context below reaches the candidate callback through globals
# because the callback is *a callback*: history iteration calls it once per
# matching command with the command and its stats, and anything else it needs
# has no parameter to arrive in.
# GLOBAL: _SMART_SUGGEST_BEST_TEXT  best candidate so far, per compute
# GLOBAL: _SMART_SUGGEST_BEST_SCORE  and its score
# GLOBAL: _SMART_SUGGEST_QUERY  the prefix being matched, per compute
# GLOBAL: _SMART_SUGGEST_MAX_REC  normalisation bounds, per compute
# GLOBAL: _SMART_SUGGEST_MAX_FREQ  normalisation bounds, per compute
# GLOBAL: _SMART_SUGGEST_CURRENT_HOST  host boost target, per compute
# GLOBAL: _SMART_ATUIN_CURRENT_HOST  hostname probe, cached once per shell

# What our own lister has drawn and when it may draw again. These survive a
# widget call because the rows they describe do: `smart-menu status` prints the
# first group, the throttle decision needs the second, and
# _smart_menu_forget_rows asks the third "is what is below the prompt mine?".
# GLOBAL: _SMART_MENU_NMATCHES  last listing's outcome, for `smart-menu status`
# GLOBAL: _SMART_MENU_LISTED  rows the current tick drew
# GLOBAL: _SMART_MENU_TRUNCATED  a listing refused for being too big
# GLOBAL: _SMART_MENU_TICKS  throttle bookkeeping
# GLOBAL: _SMART_MENU_SKIPS  throttle bookkeeping
# GLOBAL: _SMART_MENU_COOLDOWN  throttle bookkeeping
# GLOBAL: _SMART_MENU_LAST_MS  throttle bookkeeping
# GLOBAL: _SMART_MENU_ROWS  our rows still on screen, across ticks

# Our undo record for the user's completer zstyle: what was there, whether they
# had set it at all, and whether we are the ones installed. Uninstall has to
# restore "no zstyle" rather than a hard-coded default when the answer is "they
# never set one", and none of that is rebuildable from history.
# GLOBAL: _SMART_RECENT_SAVED  the completer list to go back to
# GLOBAL: _SMART_RECENT_HAD_STYLE  whether the user had one at all
# GLOBAL: _SMART_RECENT_INSTALLED  the install sentinel: the flag, not the array
# GLOBAL: _SMART_RECENT_DIRS  zsh calls the $zsh_directory_name hook by name,
#   so the table it reads cannot be a local

# native.zsh's own Tab lifecycle flag, read by nothing outside that file. A
# reset between the arming Tab and the Enter that consumes it is exactly how
# half a completion got run once already (see lib/event/zle.zsh:600).
# GLOBAL: _SMART_COMPLETION_ACTIVE  one Tab sequence, module-private
