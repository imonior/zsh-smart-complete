# lib/engine/suggest.zsh
#
# Suggestion Engine.
#
# Computes a single best inline suggestion for the current BUFFER.
#
# This file is the orchestration layer. It DOES NOT:
#   * touch ZLE
#   * touch region_highlight
#   * call fc or read $HISTFILE
#   * know what Atuin is or isn't
#
# It DOES:
#   * ask the history layer for prefix-matching candidates via the
#     well-defined callback-based iterator _smart_history_iter_prefix
#   * score each candidate via the ranking module (_smart_score_total)
#   * write the winner into state.suggestion.* so the display layer can
#     pick it up
#
# Scoring lives in lib/engine/ranking.zsh so it can be unit-tested and
# replicated 1:1 in the future Rust engine.

emulate -L zsh
setopt extended_glob no_warn_create_global

# How many distinct prefix matches to score.
: ${_SMART_SUGGEST_CANDIDATES:=64}

# ---------------------------------------------------------------------------
# Candidate accumulator.
#
# The history iterator calls _smart_suggest_on_candidate once per matching
# command. We keep the best-so-far in module-level scalars.
# ---------------------------------------------------------------------------
typeset -g _SMART_SUGGEST_BEST_TEXT=""
typeset -g _SMART_SUGGEST_BEST_SCORE=0   # integer milli, 0..1000
typeset -g _SMART_SUGGEST_QUERY=""
typeset -gi _SMART_SUGGEST_MAX_REC=0
typeset -gi _SMART_SUGGEST_MAX_FREQ=0
typeset -g _SMART_SUGGEST_CURRENT_HOST=""   # cached per compute call

# Callback signature: <cmd> <freq> <rec>
_smart_suggest_on_candidate() {
    local cmd="$1" freq="$2" rec="$3"
    local q="$_SMART_SUGGEST_QUERY"

    # Retrieve v0.1.3 CWD + v0.2.0 host/exit metadata for this command.
    local cmd_cwd current_cwd="$PWD"
    local cmd_host cmd_exit
    cmd_cwd="$(_smart_state_a_get history.cwd "$cmd" "")"
    cmd_host="$(_smart_state_a_get history.host "$cmd" "")"
    cmd_exit="$(_smart_state_a_get history.exit "$cmd" "")"

    local final
    final=$(_smart_score_total "$q" "$cmd" "$freq" "$rec" \
                "$_SMART_SUGGEST_MAX_FREQ" "$_SMART_SUGGEST_MAX_REC" \
                "$cmd_cwd" "$current_cwd" \
                "$cmd_host" "$_SMART_SUGGEST_CURRENT_HOST" \
                "$cmd_exit")

    if (( final > _SMART_SUGGEST_BEST_SCORE )); then
        _SMART_SUGGEST_BEST_TEXT="$cmd"
        _SMART_SUGGEST_BEST_SCORE=$final
    fi
    return 0   # keep iterating
}

# ---------------------------------------------------------------------------
# Public entry points
# ---------------------------------------------------------------------------

# _smart_suggest_compute <buffer>
#
# Run the full engine for <buffer>, update state.suggestion.*.
# Called ONLY from the event layer when the buffer has actually changed.
# NEVER called from line-pre-redraw, never called from a redisplay hook.
#
# Direct, non-$(…) function: writes global state directly. No stdout.
_smart_suggest_compute() {
    local buf="$1"

    # Engine disabled globally? No-op.
    case "${SMART_SUGGEST}" in
        false|no|off|0|disabled) return 0 ;;
    esac
    # Plugin runtime disable.
    (( $(_smart_state_get enabled 1) == 0 )) && return 0

    # Empty buffer → no suggestion.
    if [[ -z "$buf" ]]; then
        _smart_state_set suggestion.text ""
        _smart_state_set suggestion.source ""
        _smart_state_set suggestion.score ""
        return 0
    fi

    # Reset accumulator.
    _SMART_SUGGEST_BEST_TEXT=""
    _SMART_SUGGEST_BEST_SCORE=0
    _SMART_SUGGEST_QUERY="$buf"
    _SMART_SUGGEST_MAX_REC=$(_smart_state_get history.max_recency 0)
    _SMART_SUGGEST_MAX_FREQ=$(_smart_state_get history.max_freq 0)

    # v0.2.0: Cache current hostname once per call (host-boost normalisation).
    if [[ -z "$_SMART_SUGGEST_CURRENT_HOST" ]]; then
        if (( ${+functions[_smart_atuin_get_current_host]} )); then
            _SMART_SUGGEST_CURRENT_HOST="$(_smart_atuin_get_current_host)"
        else
            _SMART_SUGGEST_CURRENT_HOST="${HOST:-$HOSTNAME}"
        fi
    fi

    # Ask history layer for prefix candidates.
    # The iterator calls _smart_suggest_on_candidate per candidate.
    _smart_history_iter_prefix "$buf" "$_SMART_SUGGEST_CANDIDATES" _smart_suggest_on_candidate 2>/dev/null

    if [[ -n "$_SMART_SUGGEST_BEST_TEXT" && $_SMART_SUGGEST_BEST_SCORE -gt 0 ]]; then
        _smart_state_set suggestion.text   "$_SMART_SUGGEST_BEST_TEXT"
        _smart_state_set suggestion.source "history"
        _smart_state_set suggestion.score  "$(_smart_fmt_score "$_SMART_SUGGEST_BEST_SCORE")"
    else
        _smart_state_set suggestion.text ""
        _smart_state_set suggestion.source ""
        _smart_state_set suggestion.score ""
    fi
    return 0
}

# _smart_suggest_get_text <buffer>
#
# Convenience: compute + echo the current suggestion text or "". Read-only,
# safe in $() (it doesn't modify the index). Used by tests + debug.
_smart_suggest_get_text() {
    _smart_suggest_compute "$1"
    _smart_state_get suggestion.text ""
}
