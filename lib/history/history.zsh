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
# ---------------------------------------------------------------------------
# Incremental index maintenance (P0: real-time freshness)
#
# Instead of waiting SMART_HISTORY_REBUILD_EVERY commands to rebuild, we
# upsert each executed command into the in-memory index immediately:
#   * new distinct command -> unshift to _SMART_CMDS (newest), freq=1
#   * existing command     -> freq++, move to front (recency=0)
# The first-char bucket + _SMART_CMDS stay in sync; recency is re-derived
# from the array position in one O(n) pass (runs on preexec, not per
# keystroke).
# ---------------------------------------------------------------------------

# Re-derive history.recency (= array index) and count/max_recency from
# _SMART_CMDS. Direct associative writes — no subshells.
_smart_index_sync_recency() {
    local i=0 n="${#_SMART_CMDS[@]}" cmd
    # zsh indexed arrays are 1-based; recency rank is kept 0-based (array
    # position), matching the rest of the engine.
    while (( i < n )); do
        cmd="${_SMART_CMDS[$(( i + 1 ))]}"
        _smart_state_a_set history.recency "$cmd" "$i"
        (( i++ ))
    done
    _SMART_STATE[history.max_recency]="$(( ${#_SMART_CMDS[@]} - 1 ))"
    _SMART_STATE[history.count]="${#_SMART_CMDS[@]}"
    return 0
}

# Remove an occurrence of $cmd from its first-char bucket and prepend it
# (used when promoting an existing command to newest).
_smart_index_bucket_promote() {
    local cmd="$1" fc0="$2"
    local raw="${_SMART_CMDS_FIRST[$fc0]:-}"
    [[ -z "$raw" ]] && return 0
    local -a bk=() out=() c
    bk=("${(f)raw}")
    for c in "${bk[@]}"; do
        [[ "$c" == "$cmd" ]] && continue
        out+=("$c")
    done
    if (( ${#out[@]} == 0 )); then
        _SMART_CMDS_FIRST[$fc0]="$cmd"
    else
        _SMART_CMDS_FIRST[$fc0]="$cmd"$'\n'"${(F)out}"
    fi
    return 0
}

_smart_history_upsert() {
    local cmd="$1" cwd="${2:-}"
    [[ -z "$cmd" ]] && return 0
    [[ -n "$cwd" ]] && _smart_state_a_set history.cwd "$cmd" "$cwd"

    # Linear scan for the matching command. zsh indexed arrays are 1-based;
    # we keep idx 0-based because the rebuild below skips element (idx+1)
    # and the recency rank stored in the engine is also a 0-based position.
    local idx=-1 i=1 n="${#_SMART_CMDS[@]}"
    while (( i <= n )); do
        if [[ "${_SMART_CMDS[$i]}" == "$cmd" ]]; then idx=$(( i - 1 )); break; fi
        (( i++ ))
    done

    local fc0="${cmd[1]}"
    local key f mf

    if (( idx < 0 )); then
        # New distinct command -> newest.
        _SMART_CMDS=("$cmd" "${_SMART_CMDS[@]}")
        if [[ -z "${_SMART_CMDS_FIRST[$fc0]:-}" ]]; then
            _SMART_CMDS_FIRST[$fc0]="$cmd"
        else
            _SMART_CMDS_FIRST[$fc0]="$cmd"$'\n'"${_SMART_CMDS_FIRST[$fc0]}"
        fi
        _smart_state_a_set history.frequency "$cmd" 1
        mf="${_SMART_STATE[history.max_freq]:-0}"
        (( 1 > mf )) && _SMART_STATE[history.max_freq]=1
    else
        # Existing -> bump frequency.
        key="history.frequency|$cmd"
        f="${_SMART_STATE_A[$key]:-0}"
        f=$(( f + 1 ))
        _smart_state_a_set history.frequency "$cmd" "$f"
        mf="${_SMART_STATE[history.max_freq]:-0}"
        (( f > mf )) && _SMART_STATE[history.max_freq]="$f"
        # Move to front if not already there. Rebuild without the matched
        # element, then prepend. We copy element-by-element (rather than via
        # a substring slice) so space-containing commands stay intact and no
        # globbing happens. Runs on preexec, so the O(n) cost is irrelevant.
        if (( idx != 0 )); then
            local -a kept=()
            local j=1
            while (( j <= n )); do
                (( j == idx + 1 )) || kept+=("${_SMART_CMDS[$j]}")
                (( j++ ))
            done
            _SMART_CMDS=("$cmd" "${kept[@]}")
            _smart_index_bucket_promote "$cmd" "$fc0"
        fi
    fi

    _smart_index_sync_recency
    return 0
}

_smart_history_on_new_command() {
    local cmd="${1:-}"
    local threshold="${SMART_HISTORY_REBUILD_EVERY:-500}"
    (( threshold <= 0 )) && threshold=0

    # P0: reflect the just-executed command in the index immediately so it
    # becomes a candidate on the very next prompt.
    [[ -n "$cmd" ]] && _smart_history_upsert "$cmd" "$PWD"

    if (( threshold > 0 )); then
        local n="${_SMART_STATE[history.new_since]:-0}"
        n=$(( n + 1 ))
        _SMART_STATE[history.new_since]="$n"
        if (( n >= threshold )); then
            _smart_history_rebuild 2>/dev/null
        fi
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

    local count="${_SMART_STATE[history.count]:-0}"
    if (( count == 0 )); then
        _smart_history_rebuild 2>/dev/null
        count="${_SMART_STATE[history.count]:-0}"
        (( count == 0 )) && return 0
    fi

    # Prefer the first-char bucket so we only scan commands that can match.
    local -a pool=()
    local fc0="${prefix[1]}"
    if [[ -n "${_SMART_CMDS_FIRST[$fc0]:-}" ]]; then
        pool=("${(f)_SMART_CMDS_FIRST[$fc0]}")
    else
        pool=("${_SMART_CMDS[@]}")
    fi

    # NOTE: `key` must be declared HERE, once, outside the loop. Re-declaring
    # it with `local` inside the loop body (zsh 5.9) makes the variable's
    # value leak to stdout on every iteration that also invokes a function —
    # in ZLE that output goes straight to the terminal (the "key='history.…'"
    # garbage bug). See tests/test-history.zsh regression case.
    local yielded=0 cmd freq rec key
    for cmd in "${pool[@]}"; do
        [[ -z "$cmd" ]] && continue
        [[ "$cmd" == "$prefix" ]] && continue
        [[ "$cmd" == "$prefix"* ]] || continue

        # Direct associative reads — no subshell in the hot path.
        # Index via a $key variable so the compound key (which contains
        # "|" and spaces) is treated literally, not as a glob pattern.
        key="history.frequency|$cmd"; freq="${_SMART_STATE_A[$key]:-1}"
        key="history.recency|$cmd";  rec="${_SMART_STATE_A[$key]:-0}"

        "$callback" "$cmd" "$freq" "$rec" || return 0
        (( yielded++ ))
        (( yielded >= max_n )) && return 0
    done
    return 0
}
