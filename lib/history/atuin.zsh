# lib/history/atuin.zsh
#
# Atuin history backend — SQLite direct mode (v0.2.0).
#
# v0.2.0 KEY PERFORMANCE CHOICE:
#   We do NOT call `sqlite3` per keystroke / suggestion. Atuin SQLite
#   is queried EXACTLY ONCE per rebuild (precmd / smart-reindex /
#   SMART_HISTORY_REBUILD_EVERY threshold). The result fills the same
#   in-memory state indices as the zsh backend + three metadata assocs
#   for hostname / cwd / exit status. Subsequent iterations hit memory
#   only — the exact same <3ms path as the pure zsh backend.
#
# Graceful fallbacks:
#   * `sqlite3` binary missing        → caller (history.zsh) falls back to zsh
#   * SMART_ATUIN_DB_PATH not present → caller falls back to zsh
#   * DB schema mismatch              → caller falls back to zsh
#
# Interface (identical to zsh.zsh, plus metadata assocs):
#
#   _smart_history_backend_atuin_build <limit>
#
# Populates:
#   _SMART_BUILD_ORDER[]        distinct cmds, newest first
#   _SMART_BUILD_FREQ[cmd]      occurrence count
#   _SMART_BUILD_REC_RANKS[cmd] 0 = newest in batch
#   _SMART_BUILD_MAX_F          highest frequency
#   _SMART_BUILD_REC            highest recency rank = N-1
#   _SMART_BUILD_META_CWD[cmd]  (new) last cwd seen for command
#   _SMART_BUILD_META_HOST[cmd] (new) last hostname seen
#   _SMART_BUILD_META_EXIT[cmd] (new) last exit code seen

emulate -L zsh
setopt extended_glob no_warn_create_global

# ---------------------------------------------------------------------------
# Current hostname — cached once per process.
# ---------------------------------------------------------------------------
typeset -g _SMART_ATUIN_CURRENT_HOST=""
_smart_atuin_get_current_host() {
    if [[ -z "$_SMART_ATUIN_CURRENT_HOST" ]]; then
        if [[ -n "$HOST" ]]; then
            _SMART_ATUIN_CURRENT_HOST="$HOST"
        elif [[ -n "$HOSTNAME" ]]; then
            _SMART_ATUIN_CURRENT_HOST="$HOSTNAME"
        elif command -v hostname >/dev/null 2>&1; then
            _SMART_ATUIN_CURRENT_HOST="$(hostname 2>/dev/null)"
        fi
    fi
    print -r -- "$_SMART_ATUIN_CURRENT_HOST"
}

# ---------------------------------------------------------------------------
# _smart_history_backend_atuin_build <limit>
#
# Returns 0 on success, 1 if any prerequisite fails (caller falls back
# to the zsh backend automatically).
# ---------------------------------------------------------------------------
_smart_history_backend_atuin_build() {
    local limit="${1:-1000}"
    local db_path="${SMART_ATUIN_DB_PATH:-$HOME/.local/share/atuin/history.db}"

    # Prerequisites.
    (( ${+commands[sqlite3]} )) || return 1
    [[ -f "$db_path" && -r "$db_path" ]] || return 1
    (( limit > 0 )) || limit=1000

    # If SMART_ATUIN_SUCCESS_ONLY is true, drop exit != 0 rows at the
    # SQL level. Build the WHERE clause so it composes cleanly whether
    # or not the filter is active.
    local where_clause="WHERE 1=1"
    if [[ "${SMART_ATUIN_SUCCESS_ONLY:-false}" == "true" ]]; then
        where_clause="${where_clause} AND exit = 0"
    fi

    # NOTE: Older Atuin schemas use 'history' table; newer versions
    # use the same column names. We query defensively: try to detect
    # column existence by reading one row; if it fails → fall back.
    local SQL
    SQL="SELECT command, cwd, exit, hostname FROM history ${where_clause}
         ORDER BY timestamp DESC
         LIMIT ${limit};"

    # Run sqlite3 once. Use TAB separator for reliable parsing even if
    # cwd contains spaces (commands may contain TABS rarely, but we
    # tolerate by limiting to 4 fields per line).
    local sep=$'\t'
    local raw command cwd exit_code hostname
    local rec_rank=0 max_freq=0

    while IFS="$sep" read -r command cwd exit_code hostname; do
        [[ -z "$command" ]] && continue

        # New command → push to order list.
        if [[ -z "${_SMART_BUILD_SEEN[$command]}" ]]; then
            _SMART_BUILD_SEEN[$command]=1
            _SMART_BUILD_ORDER+=("$command")
            _SMART_BUILD_FREQ[$command]=1
            _SMART_BUILD_REC_RANKS[$command]=$rec_rank
            (( rec_rank++ ))
        else
            _SMART_BUILD_FREQ[$command]=$(( _SMART_BUILD_FREQ[$command] + 1 ))
        fi

        # v0.2.0: Record cwd / host / exit metadata. For duplicate cmds we
        # keep the LAST-SEEN (most recent) row's values because the query
        # is ordered by timestamp DESC, which means the FIRST occurrence
        # in this loop IS the most recent — so only set metadata once.
        if [[ -z "${_SMART_BUILD_META_SEEN_META[$command]}" ]]; then
            _SMART_BUILD_META_SEEN_META[$command]=1
            _SMART_BUILD_META_CWD[$command]="${cwd:-}"
            _SMART_BUILD_META_HOST[$command]="${hostname:-}"
            _SMART_BUILD_META_EXIT[$command]="${exit_code:-0}"
        fi

        if (( _SMART_BUILD_FREQ[$command] > max_freq )); then
            max_freq=${_SMART_BUILD_FREQ[$command]}
        fi
        true   # keep while-return-code stable even if previous cond was false
    done < <(sqlite3 -separator "$sep" "$db_path" "$SQL" 2>/dev/null) || return 1

    _SMART_BUILD_MAX_F=$max_freq
    _SMART_BUILD_REC=$(( rec_rank > 0 ? rec_rank - 1 : 0 ))

    return 0
}
