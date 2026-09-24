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
#   _SMART_STATE_L[history.cmds]   → distinct commands (membership; newest
#                                    first right after a rebuild)
#   _SMART_STATE_A["history.frequency|<cmd>"] → occurrence count
#   _SMART_STATE_A["history.recency|<cmd>"]  → last-use TICK (higher = newer)
#   _SMART_STATE[history.count]    → number of distinct commands
#   _SMART_STATE[history.max_freq] → highest frequency (for normalisation)
#   _SMART_STATE[history.max_recency] → upper bound on any current age
#   _SMART_STATE[history.tick]     → global monotonic last-use counter
#
# Recency is a tick, not an array position. The engine ranks by AGE
# (= history.tick - last-use tick), which one associative write per executed
# command keeps exact. The previous model stored the position inside
# _SMART_CMDS, so promoting a command silently shifted the rank of everything
# behind it and every Enter re-derived all ranks in an O(index) pass. The
# array is now a pure membership list (recency ORDER lives in the first-char
# buckets); right after a rebuild both it and the buckets hold the backend's
# newest-first order, and incremental updates keep the buckets current.

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

    # Persist frequencies + recency into state. The backend hands us a rank
    # (0 = newest); store it as tick = base - rank so the ages the engine
    # computes right after the rebuild equal the ranks, and later per-command
    # ticks continue upward from base.
    local base="${_SMART_STATE[history.tick]:-0}"
    (( base < _SMART_BUILD_REC )) && base=$_SMART_BUILD_REC
    local c
    for c in "${_SMART_BUILD_ORDER[@]}"; do
        _smart_state_a_set history.frequency "$c" "${_SMART_BUILD_FREQ[$c]}"
        _smart_state_a_set history.recency   "$c" "$(( base - _SMART_BUILD_REC_RANKS[$c] ))"
        # v0.2.0: Persist metadata (cwd/host/exit) if present.
        # Only write non-empty values; tests & zsh backend may leave empty.
        [[ -n "${_SMART_BUILD_META_CWD[$c]+s}"  && -n "${_SMART_BUILD_META_CWD[$c]}" ]] \
            && _smart_state_a_set history.cwd  "$c" "${_SMART_BUILD_META_CWD[$c]}"
        [[ -n "${_SMART_BUILD_META_HOST[$c]+s}" && -n "${_SMART_BUILD_META_HOST[$c]}" ]] \
            && _smart_state_a_set history.host "$c" "${_SMART_BUILD_META_HOST[$c]}"
        [[ -n "${_SMART_BUILD_META_EXIT[$c]+s}" ]] \
            && _smart_state_a_set history.exit "$c" "${_SMART_BUILD_META_EXIT[$c]}"
    done

    # Persist the distinct-command list (backend order: newest first).
    _smart_state_l_set history.cmds "${_SMART_BUILD_ORDER[@]}"

    _smart_state_set history.count "${#_SMART_BUILD_ORDER}"
    _smart_state_set history.max_freq "$_SMART_BUILD_MAX_F"
    _smart_state_set history.max_recency "$_SMART_BUILD_REC"
    _smart_state_set history.tick "$base"
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
#   * new distinct command -> append to _SMART_CMDS, freq=1, prepend its
#     first-char bucket
#   * existing command     -> freq++, prepend its first-char bucket
#   * either way           -> ONE recency write: re-stamp the command's tick.
# Recency ORDER lives in the first-char buckets (the candidate pools the
# engine actually iterates); _SMART_CMDS carries membership only. That is what
# makes this path O(1) amortised. The previous shape kept the array itself in
# newest-first order, so every Enter paid a full-array scan to locate the
# command, a full-array copy to move it, and a full-array pass to re-stamp the
# ranks shifted by the move — hundreds of milliseconds per Enter at 20k
# distinct commands, all of it removed by this design.
# ---------------------------------------------------------------------------

# Make $cmd the newest entry of its first-char bucket (prepend; drop any
# older copy). No-op when it is already at the head — the common case when a
# command repeats.
_smart_index_bucket_promote() {
    local cmd="$1" fc0="$2"
    local raw="${_SMART_CMDS_FIRST[$fc0]:-}"
    [[ "$raw" == "$cmd" || "$raw" == "$cmd"$'\n'* ]] && return 0
    if [[ -z "$raw" ]]; then
        _SMART_CMDS_FIRST[$fc0]="$cmd"
        return 0
    fi
    local -a bk=("${(f)raw}")
    # Remove the older copy with an array filter rather than a per-element
    # loop: ${arr:#pat} runs at C speed, and a pattern that reaches it by
    # expansion is matched literally, so only the exact command disappears
    # (a command containing *, $ or [ is an ordinary history line here). The
    # loop this replaces cost ~2.6 microseconds per bucket entry, i.e. ~5 ms
    # on every Enter that repeated an old command from a 16k index.
    bk=("${(@)bk:#${cmd}}")
    _SMART_CMDS_FIRST[$fc0]="$cmd"$'\n'"${(F)bk}"
    return 0
}

# Drop every index slot for a command. Used when capping _SMART_CMDS so a
# disabled auto-rebuild (SMART_HISTORY_REBUILD_EVERY=0) cannot grow the
# in-memory index without bound.
_smart_history_forget() {
    local cmd="$1" fc0="${cmd[1]}" raw
    local -a out=()
    raw="${_SMART_CMDS_FIRST[$fc0]:-}"
    if [[ -n "$raw" ]]; then
        out=("${(f)raw}")
        out=("${(@)out:#${cmd}}")
        if (( ${#out[@]} == 0 )); then
            unset "_SMART_CMDS_FIRST[$fc0]"
        else
            _SMART_CMDS_FIRST[$fc0]="${(F)out}"
        fi
    fi
    unset "_SMART_STATE_A[history.frequency|$cmd]"
    unset "_SMART_STATE_A[history.recency|$cmd]"
    unset "_SMART_STATE_A[history.cwd|$cmd]"
    unset "_SMART_STATE_A[history.host|$cmd]"
    unset "_SMART_STATE_A[history.exit|$cmd]"
}

_smart_history_upsert() {
    local cmd="$1" cwd="${2:-}"
    local limit="${SMART_SUGGEST_HISTORY_LIMIT:-20000}"
    [[ -z "$cmd" ]] && return 0
    [[ -n "$cwd" ]] && _smart_state_a_set history.cwd "$cmd" "$cwd"

    # Membership is an associative lookup. history.frequency is written when a
    # command enters the index and unset when it is evicted, so it doubles as
    # the membership map — no array scan.
    local fc0="${cmd[1]}"
    local key="history.frequency|$cmd" f mf

    if [[ -z "${_SMART_STATE_A[$key]+s}" ]]; then
        # New distinct command: append for membership (O(1) amortised; the
        # old front-insert copied the whole array on every new command),
        # prepend in its bucket for recency order (O(bucket)).
        _SMART_CMDS+=("$cmd")
        # Cap in-memory index size: when SMART_HISTORY_REBUILD_EVERY=0 disables
        # the periodic full rebuild, drop the entry inserted longest ago
        # (head) so _SMART_CMDS cannot grow without bound. The bucket + assoc
        # slots stay in sync. `shift` moves the array's element pointers in
        # one C-level step; the old element-by-element copy loop cost a
        # zsh-speed 20k-element pass per Enter once the index sat at its cap
        # (and _SMART_CMDS=("${_SMART_CMDS[2,-1]}") is NOT an option — the
        # outer quotes join every element into a single string in zsh).
        if (( ${#_SMART_CMDS[@]} > limit )); then
            local oldest="${_SMART_CMDS[1]}"
            shift _SMART_CMDS
            _smart_history_forget "$oldest"
        fi
        _smart_index_bucket_promote "$cmd" "$fc0"
        _SMART_STATE_A[$key]=1
        mf="${_SMART_STATE[history.max_freq]:-0}"
        (( 1 > mf )) && _SMART_STATE[history.max_freq]=1
    else
        # Existing -> bump frequency, and make it newest in its bucket.
        f="${_SMART_STATE_A[$key]}"
        (( ++f ))
        _SMART_STATE_A[$key]="$f"
        mf="${_SMART_STATE[history.max_freq]:-0}"
        (( f > mf )) && _SMART_STATE[history.max_freq]="$f"
        _smart_index_bucket_promote "$cmd" "$fc0"
    fi

    # Recency: one tick stamp, O(1). It replaces the full-array rescan; the
    # engine compares commands by AGE = history.tick - this tick, so every
    # other command's stored value stays valid untouched.
    local tick=$(( ${_SMART_STATE[history.tick]:-0} + 1 ))
    _SMART_STATE[history.tick]="$tick"
    key="history.recency|$cmd"
    _SMART_STATE_A[$key]="$tick"
    # An age never exceeds the current tick (stored ticks are >= 0), so this
    # is a sound normalisation bound without needing the true oldest entry.
    _SMART_STATE[history.max_recency]="$tick"
    _SMART_STATE[history.count]="${#_SMART_CMDS[@]}"
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
    local now_tick="${_SMART_STATE[history.tick]:-0}"
    local yielded=0 cmd freq rec key
    for cmd in "${pool[@]}"; do
        [[ -z "$cmd" ]] && continue
        [[ "$cmd" == "$prefix" ]] && continue
        [[ "$cmd" == "$prefix"* ]] || continue

        # Direct associative reads — no subshell in the hot path.
        # Index via a $key variable so the compound key (which contains
        # "|" and spaces) is treated literally, not as a glob pattern.
        key="history.frequency|$cmd"; freq="${_SMART_STATE_A[$key]:-1}"
        # Rank candidates by AGE (commands executed since last use, 0 = just
        # used); history.recency stores the last-use tick, and an unstamped
        # command is treated as newest — the same fallback the rank model had.
        key="history.recency|$cmd"
        rec="${_SMART_STATE_A[$key]:-$now_tick}"
        (( rec = now_tick - rec ))

        "$callback" "$cmd" "$freq" "$rec" || return 0
        (( yielded++ ))
        (( yielded >= max_n )) && return 0
    done
    return 0
}
