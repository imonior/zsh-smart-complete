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
#   history.max_recency    number             -- for ranking normalisation
#   last_err               string             -- last silent error, for debug

# Canonical sub-maps in _SMART_STATE_A:
#   history.freq           cmd -> occurrence count
#   history.recency        cmd -> recency rank (0 = newest, higher = older)
#   history.first_char     "git" -> "g d c l ..."  -- TODO: for future trie

# Canonical lists in _SMART_STATE_L:
#   history.cmds           ordered array: newest distinct command first

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
    # Stored joined with \x1f so we can round-trip spaces in entries.
    print -r -- "${existing}" | tr '\037' '\n'
    return 0
}

# _smart_state_l_set <list> <args..> -- replace the whole list.
# Call directly (no $() subshell) so the write persists.
_smart_state_l_set() {
    local sub="$1"; shift
    local joined="" v
    for v in "$@"; do
        if [[ -z "$joined" ]]; then
            joined="$v"
        else
            joined+=$'\x1f'"$v"
        fi
    done
    _SMART_STATE_L[$sub]="$joined"
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
    return 0
}

# Initialise on first load.
_smart_state_reset
