# lib/state.zsh
#
# Central state container.
#
# RULE: Every piece of mutable, cross-module runtime data lives in one of the
# associative arrays declared here. You will never see `_smart_some_thing=foo`
# as a standalone scalar variable anywhere else in this codebase.
#
# Why a single state object?
#   * It is trivial to dump / snapshot / reset for debugging.
#   * It maps 1:1 onto a future struct SmartState in the independent shell.
#   * It prevents the "37 unrelated global scalars" rot that kills every
#     zsh plugin past 1000 LoC.

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
#   suggestion.source      "history|atuin|native" -- where it came from
#   suggestion.score       "0.000"-like       -- fixed-point score
#   history.count          number             -- distinct commands indexed
#   history.rebuilt_at     epoch seconds      -- last index rebuild
#   history.new_since      number             -- new commands since rebuild
#   history.max_freq       number             -- for ranking normalisation
#   history.max_recency    number             -- upper bound on any age
#   history.tick           number             -- monotonic last-use counter
#   last_err               string             -- last silent error, for debug

# Canonical sub-maps in _SMART_STATE_A:
#   history.freq           cmd -> occurrence count
#   history.recency        cmd -> last-use tick (see history.max_recency;
#                          age = tick - stored, 0 = just used)
#   history.first_char     "git" -> "g d c l ..."  -- TODO: for future trie

# Canonical lists in _SMART_STATE_L:
#   history.cmds           distinct commands; recency ORDER lives in the
#                          first-char buckets (see _SMART_CMDS_FIRST)

# ---------------------------------------------------------------------------
# Accessors
# ---------------------------------------------------------------------------
# All modules read/write state through these helpers so we can validate,
# log or migrate keys in one place.

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
# Full reset (used by smart-reindex + tests)
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
