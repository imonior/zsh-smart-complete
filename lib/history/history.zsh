# lib/history/history.zsh
#
# In-memory history index — core dispatcher.
#
# CRITICAL rule: WE DO NOT USE ${history}.
#
# This file is the core of the history layer. It:
#   1. Dispatches to the configured backend (zsh or atuin) to read raw history.
#   2. Persists the resulting index into the state container.
#   3. Provides the prefix-iteration interface that the suggestion engine calls.
#
# Backends (lib/history/zsh.zsh, lib/history/atuin.zsh) implement:
#   _smart_history_backend_<name>_build <limit>
#   They populate _SMART_BUILD_* arrays by reference.
#
# Index layout (stored in state):
#
#   _SMART_STATE_L[history.cmds]   → ordered distinct commands, newest first
#   _SMART_STATE_A["history.frequency|<cmd>"] → occurrence count
#   _SMART_STATE_A["history.recency|<cmd>"]  → 0 = newest, N-1 = oldest
#   _SMART_STATE[history.count]    → number of distinct commands
#   _SMART_STATE[history.max_freq] → highest frequency (for normalisation)
#   _SMART_STATE[history.max_recency] → highest recency rank (for normalisation)

emulate -L zsh
setopt extended_glob no_warn_create_global

# ---------------------------------------------------------------------------
# _smart_history_rebuild
#
# Drop the existing index and rebuild from scratch via the configured backend.
# Called from the bootstrap precmd and from `smart-reindex`.
# ---------------------------------------------------------------------------
_smart_history_rebuild() {
    # Drop every existing history slot.
    _smart_state_a_unset_sub "history.frequency"
    _smart_state_a_unset_sub "history.recency"
    _smart_state_a_unset_sub "history.cwd"
    _smart_state_a_unset_sub "history.host"
    _smart_state_a_unset_sub "history.exit"
    _SMART_STATE_L[history.cmds]=""

    local limit="${SMART_SUGGEST_HISTORY_LIMIT:-20000}"
    local now_ts
    now_ts=$(command date +%s 2>/dev/null || print -r -- 0)

    # Scratch arrays populated by the backend.
    typeset -ga _SMART_BUILD_ORDER=()
    typeset -gA _SMART_BUILD_FREQ=()
    typeset -gA _SMART_BUILD_SEEN=()
    typeset -gA _SMART_BUILD_REC_RANKS=()
    typeset -gi _SMART_BUILD_MAX_F=0
    typeset -gi _SMART_BUILD_REC=0
    # v0.2.0 metadata assocs (hostname/cwd/exit per cmd).
    typeset -gA _SMART_BUILD_META_CWD=()
    typeset -gA _SMART_BUILD_META_HOST=()
    typeset -gA _SMART_BUILD_META_EXIT=()
    typeset -gA _SMART_BUILD_META_SEEN_META=()

    # Dispatch to backend.
    local backend="${SMART_HISTORY_BACKEND:-zsh}"
    local rc=1
    case "$backend" in
        atuin)
            (( ${+functions[_smart_history_backend_atuin_build]} )) && \
                _smart_history_backend_atuin_build "$limit"; rc=$?
            ;;
        smart-engine)
            # Reserved for future Rust IPC backend.
            rc=1
            ;;
        zsh|*)
            _smart_history_backend_zsh_build "$limit"; rc=$?
            ;;
    esac

    # If the chosen backend failed (e.g. atuin not installed), fall back to zsh.
    if (( rc != 0 )) || (( ${#_SMART_BUILD_ORDER} == 0 )); then
        _SMART_BUILD_ORDER=()
        _SMART_BUILD_FREQ=()
        _SMART_BUILD_SEEN=()
        _SMART_BUILD_REC_RANKS=()
        _SMART_BUILD_MAX_F=0
        _SMART_BUILD_REC=0
        _SMART_BUILD_META_CWD=()
        _SMART_BUILD_META_HOST=()
        _SMART_BUILD_META_EXIT=()
        _SMART_BUILD_META_SEEN_META=()
        _smart_history_backend_zsh_build "$limit" 2>/dev/null
    fi

    # Persist frequencies + recency into state.
    local c
    for c in "${_SMART_BUILD_ORDER[@]}"; do
        _smart_state_a_set history.frequency "$c" "${_SMART_BUILD_FREQ[$c]}"
        _smart_state_a_set history.recency   "$c" "${_SMART_BUILD_REC_RANKS[$c]}"
        # v0.2.0: Persist metadata (cwd/host/exit) if present.
        # Only write non-empty values; tests & zsh backend may leave empty.
        [[ -n "${_SMART_BUILD_META_CWD[$c]+s}"  && -n "${_SMART_BUILD_META_CWD[$c]}" ]] \
            && _smart_state_a_set history.cwd  "$c" "${_SMART_BUILD_META_CWD[$c]}"
        [[ -n "${_SMART_BUILD_META_HOST[$c]+s}" && -n "${_SMART_BUILD_META_HOST[$c]}" ]] \
            && _smart_state_a_set history.host "$c" "${_SMART_BUILD_META_HOST[$c]}"
        [[ -n "${_SMART_BUILD_META_EXIT[$c]+s}" ]] \
            && _smart_state_a_set history.exit "$c" "${_SMART_BUILD_META_EXIT[$c]}"
    done

    # Persist the ordered distinct-command list (newest first).
    _smart_state_l_set history.cmds "${_SMART_BUILD_ORDER[@]}"

    _smart_state_set history.count "${#_SMART_BUILD_ORDER}"
    _smart_state_set history.max_freq "$_SMART_BUILD_MAX_F"
    _smart_state_set history.max_recency "$_SMART_BUILD_REC"
    _smart_state_set history.rebuilt_at "$now_ts"
    _smart_state_set history.new_since 0

    # Clean up scratch arrays.
    unset _SMART_BUILD_ORDER _SMART_BUILD_FREQ _SMART_BUILD_SEEN \
          _SMART_BUILD_REC_RANKS _SMART_BUILD_MAX_F _SMART_BUILD_REC \
          _SMART_BUILD_META_CWD _SMART_BUILD_META_HOST \
          _SMART_BUILD_META_EXIT _SMART_BUILD_META_SEEN_META 2>/dev/null

    return 0
}

# ---------------------------------------------------------------------------
# _smart_history_on_new_command
#
# Cheap per-command hook. Records that N commands have been executed since
# the last rebuild and triggers an auto-rebuild if the threshold is hit.
# ---------------------------------------------------------------------------
_smart_history_on_new_command() {
    local cmd="${1:-}"
    # v0.1.3: Record CWD for this command (for CWD relevance boost).
    [[ -n "$cmd" ]] && _smart_state_a_set history.cwd "$cmd" "$PWD" 2>/dev/null

    local threshold="${SMART_HISTORY_REBUILD_EVERY:-500}"
    (( threshold <= 0 )) && return 0

    local n
    n=$(_smart_state_get history.new_since 0)
    n=$(( n + 1 ))
    _smart_state_set history.new_since "$n"

    if (( n >= threshold )); then
        _smart_history_rebuild 2>/dev/null
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _smart_history_iter_prefix <prefix> <max_candidates> <callback>
#
# Walk `history.cmds` (which is already in recency order) and for each
# command that starts with $prefix, call:
#
#    $callback <cmd> <frequency> <recency_rank>
#
# Stops after <max_candidates> callbacks.
# ---------------------------------------------------------------------------
_smart_history_iter_prefix() {
    local prefix="$1" max_n="$2" callback="$3"
    [[ -z "$prefix" ]] && return 0
    (( max_n <= 0 )) && return 0

    local count
    count=$(_smart_state_get history.count 0)
    if (( count == 0 )); then
        _smart_history_rebuild 2>/dev/null
        count=$(_smart_state_get history.count 0)
        (( count == 0 )) && return 0
    fi

    local joined="${_SMART_STATE_L[history.cmds]}"
    [[ -z "$joined" ]] && return 0

    local -a cmds=()
    local sep=$'\x1f'
    IFS="$sep" read -r -A cmds <<< "$joined"

    local yielded=0 cmd freq rec
    for cmd in "${cmds[@]}"; do
        [[ -z "$cmd" ]] && continue
        [[ "$cmd" == "$prefix" ]] && continue
        [[ "$cmd" == "$prefix"* ]] || continue

        freq="$(_smart_state_a_get history.frequency "$cmd" 1)"
        rec="$(_smart_state_a_get history.recency "$cmd" 0)"

        "$callback" "$cmd" "$freq" "$rec" || return 0
        (( yielded++ ))
        (( yielded >= max_n )) && return 0
    done
    return 0
}
