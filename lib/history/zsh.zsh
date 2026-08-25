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
    local line cmd
    local rec_rank=0 max_freq=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip leading whitespace that `fc -n` habitually emits.
        cmd="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$cmd" ]] && continue

        if [[ -z "${_SMART_BUILD_SEEN[$cmd]}" ]]; then
            _SMART_BUILD_SEEN[$cmd]=1
            _SMART_BUILD_ORDER+=("$cmd")
            _SMART_BUILD_FREQ[$cmd]=1
            _SMART_BUILD_REC_RANKS[$cmd]=$rec_rank
            (( rec_rank++ ))
        else
            _SMART_BUILD_FREQ[$cmd]=$(( _SMART_BUILD_FREQ[$cmd] + 1 ))
        fi
        if (( _SMART_BUILD_FREQ[$cmd] > max_freq )); then
            max_freq=${_SMART_BUILD_FREQ[$cmd]}
        fi
        true   # keep while-return stable
    done < <(fc -ln -r -${limit} 2>/dev/null)

    _SMART_BUILD_MAX_F=$max_freq
    _SMART_BUILD_REC=$(( rec_rank > 0 ? rec_rank - 1 : 0 ))
    return 0
}
