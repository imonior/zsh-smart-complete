# lib/history/zsh.zsh
#
# Zsh history backend.
#
# Uses `fc` (the builtin, NOT the `${history}` special parameter) to
# read the shell's history and populate the in-memory index.
#
# This is one of two interchangeable backends. The other is atuin.zsh.
# Both implement the same interface:
#
#   _smart_history_backend_zsh_build <limit>
#
#   Populates three local-by-convention arrays passed by reference:
#     - _SMART_BUILD_ORDER  (array: distinct commands, newest first)
#     - _SMART_BUILD_FREQ   (assoc: command → count)
#     - _SMART_BUILD_MAX_F  (scalar: highest frequency)
#     - _SMART_BUILD_REC    (scalar: highest recency rank = count-1)
#
# The caller (history.zsh core) persists these into the state container.

emulate -L zsh
setopt extended_glob no_warn_create_global

_smart_history_backend_zsh_build() {
    local limit="$1"
    local line cmd f
    local rec_rank=0 max_freq=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip leading whitespace that `fc -n` habitually emits.
        cmd="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$cmd" ]] && continue

        # NEVER put $cmd bare inside (( )) or $(( )) -- not even as a subscript:
        # zsh re-evaluates the subscript as an arithmetic expression. Measured on
        # 5.9 against a seeded history file: a line containing `$(touch f)' had
        # that substitution EXECUTED during indexing, and a line with an
        # unbalanced `]' raised "bad math expression" -- and on one real user's
        # 912-line history the evaluation never returned at all, which left the
        # index empty and, because _smart_bootstrap_once binds its ZLE widgets
        # only after the rebuild, disabled the whole plugin. Callers discard
        # stderr, so none of that was visible. The count therefore travels
        # through a scalar, which is only ever read as text.
        if [[ -z "${_SMART_BUILD_SEEN[$cmd]}" ]]; then
            _SMART_BUILD_SEEN[$cmd]=1
            _SMART_BUILD_ORDER+=("$cmd")
            _SMART_BUILD_REC_RANKS[$cmd]=$rec_rank
            (( rec_rank++ ))
            f=1
        else
            f=$(( ${_SMART_BUILD_FREQ[$cmd]} + 1 ))
        fi
        _SMART_BUILD_FREQ[$cmd]=$f
        if (( f > max_freq )); then
            max_freq=$f
        fi
        true   # keep while-return stable
    done < <(fc -ln -r -${limit} 2>/dev/null)

    _SMART_BUILD_MAX_F=$max_freq
    _SMART_BUILD_REC=$(( rec_rank > 0 ? rec_rank - 1 : 0 ))
    return 0
}
