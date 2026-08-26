# lib/engine/ranking.zsh
#
# Ranking Engine.
#
# Pure scoring functions. No ZLE, no state writes, no history reads.
# Given a candidate command + its metadata + index-wide maxima, produce
# an integer 0..1000 score. The suggestion engine calls these to rank
# candidates from the history iterator.
#
# Scoring model (all integer arithmetic, no floats):
#
#   score  =  weight_prefix    * prefix_score
#          +  weight_recency   * recency_score
#          +  weight_frequency * frequency_score
#
#   weights sum to 1000 (milli-units).
#   each sub-score is already in [0, 1000].
#   final value is in [0, 1000].
#
# Future Rust engine will replicate this exact model:
#
#   struct Scoring {
#       w_prefix: u32,      // 400
#       w_recency: u32,     // 350
#       w_frequency: u32,   // 250
#   }
#   fn score(prefix, rec, freq, max_rec, max_freq) -> u32 { ... }

emulate -L zsh
setopt extended_glob no_warn_create_global

# Hot-path return value for the internal _smart_x_* scoring functions, so
# _smart_score_total / _smart_suggest_on_candidate avoid $(…) subshells.
typeset -g _SMART_SCORE_RET=0

# ---------------------------------------------------------------------------
# Tunables (milli-units, must sum to 1000).
# ---------------------------------------------------------------------------
: ${_SMART_W_PREFIX:=400}
: ${_SMART_W_RECENCY:=350}
: ${_SMART_W_FREQ:=250}

# v0.1.3: Exponential decay alpha (integer milli). Default 10 (≈0.01).
: ${_SMART_RANKING_DECAY_ALPHA:=${SMART_RANKING_DECAY_ALPHA:-10}}
# v0.1.3: CWD boost multiplier (milli). Default 1500 (1.5x).
: ${_SMART_RANKING_CWD_BOOST:=${SMART_RANKING_CWD_BOOST:-1500}}
# v0.2.0: Same-host boost multiplier (milli). Default 1300 (1.3x).
: ${_SMART_RANKING_HOST_BOOST:=${SMART_ATUIN_HOST_BOOST:-1300}}
# v0.2.0: Failed-exit penalty multiplier (milli). Default 500 (0.5x).
: ${_SMART_RANKING_FAILED_PENALTY:=${SMART_ATUIN_FAILED_PENALTY:-500}}

# ---------------------------------------------------------------------------
# _smart_score_prefix <prefix> <cmd> → 0..1000
#
# Higher = better. The more of the command the user has already typed,
# the more relevant the suggestion feels.
# ---------------------------------------------------------------------------
_smart_x_prefix() {
    local prefix="$1" cmd="$2"
    local plen=${#prefix} clen=${#cmd}
    if (( clen == 0 )) || (( clen == plen )); then
        _SMART_SCORE_RET=0; return
    fi
    local ratio=$(( 1000 * plen / clen ))
    if   (( ratio >= 750 )); then _SMART_SCORE_RET=1000
    elif (( ratio >= 500 )); then _SMART_SCORE_RET=850
    elif (( ratio >= 300 )); then _SMART_SCORE_RET=650
    elif (( ratio >= 150 )); then _SMART_SCORE_RET=450
    else                          _SMART_SCORE_RET=250
    fi
}
_smart_score_prefix() {
    _smart_x_prefix "$@"
    print -r -- "$_SMART_SCORE_RET"
}

# ---------------------------------------------------------------------------
# _smart_score_recency <rec> <max_rec> → 0..1000
#
# v0.1.3: Exponential time decay (replaces linear bucketing).
# rec=0 = newest, max_rec = oldest in index.
#
#   score = 1000000 / (1000 + alpha * rec)
#
# With alpha=10: rec=0→1000, rec=50→667, rec=200→333, rec=500→167.
# With alpha=50: rec=0→1000, rec=10→667, rec=50→286, rec=100→167.
# All integer arithmetic — no floats.
# ---------------------------------------------------------------------------
_smart_x_recency() {
    local rec="$1" max_rec="$2"
    local alpha="${_SMART_RANKING_DECAY_ALPHA:-10}"
    (( rec < 0 )) && rec=0
    (( max_rec >= 0 )) && (( rec > max_rec )) && rec=$max_rec
    # Exponential decay: 1000000 / (1000 + alpha * rec)
    local denom=$(( 1000 + alpha * rec ))
    (( denom <= 0 )) && denom=1000
    local score=$(( 1000000 / denom ))
    (( score < 0 )) && score=0
    (( score > 1000 )) && score=1000
    _SMART_SCORE_RET=$score
}
_smart_score_recency() {
    _smart_x_recency "$@"
    print -r -- "$_SMART_SCORE_RET"
}

# ---------------------------------------------------------------------------
# _smart_score_frequency <freq> <max_freq> → 0..1000
#
# S-shaped: only the very-frequent commands get a high bonus.
# ---------------------------------------------------------------------------
_smart_x_frequency() {
    local freq="$1" max_freq="$2"
    (( max_freq <= 0 )) && max_freq=1
    (( freq <= 0 )) && freq=1
    (( freq > max_freq )) && freq=$max_freq
    local frac=$(( 1000 * freq / max_freq ))
    if   (( frac >= 900 )); then _SMART_SCORE_RET=1000
    elif (( frac >= 600 )); then _SMART_SCORE_RET=820
    elif (( frac >= 300 )); then _SMART_SCORE_RET=560
    elif (( frac >= 100 )); then _SMART_SCORE_RET=300
    else                          _SMART_SCORE_RET=120
    fi
}
_smart_score_frequency() {
    _smart_x_frequency "$@"
    print -r -- "$_SMART_SCORE_RET"
}

# ---------------------------------------------------------------------------
# _smart_score_cwd <cmd_cwd> <current_cwd> → 1000 or boost value
#
# v0.1.3: CWD relevance boost. If the command was last executed in the
# same directory as the current $PWD, return the boost multiplier
# (e.g. 1500 = 1.5x). Otherwise return 1000 (1.0x = no change).
# ---------------------------------------------------------------------------
_smart_x_cwd() {
    local cmd_cwd="$1" current_cwd="$2"
    if [[ -n "$cmd_cwd" && "$cmd_cwd" == "$current_cwd" ]]; then
        _SMART_SCORE_RET=${_SMART_RANKING_CWD_BOOST:-1500}
    else
        _SMART_SCORE_RET=1000
    fi
}
_smart_score_cwd() {
    _smart_x_cwd "$@"
    print -r -- "$_SMART_SCORE_RET"
}

# ---------------------------------------------------------------------------
# _smart_score_host <cmd_host> <current_host> → 1000 or boost value
#
# v0.2.0: Same-host boost for Atuin multi-device histories. If a command
# was run on the current host, return the boost multiplier. Otherwise
# return 1000 (no change). If either input is empty = unknown, no boost.
# ---------------------------------------------------------------------------
_smart_x_host() {
    local cmd_host="$1" current_host="$2"
    if [[ -n "$cmd_host" && -n "$current_host" && "$cmd_host" == "$current_host" ]]; then
        _SMART_SCORE_RET=${_SMART_RANKING_HOST_BOOST:-1300}
    else
        _SMART_SCORE_RET=1000
    fi
}
_smart_score_host() {
    _smart_x_host "$@"
    print -r -- "$_SMART_SCORE_RET"
}

# ---------------------------------------------------------------------------
# _smart_score_exit <exit_code> → 1000 or penalty value
#
# v0.2.0: Failed-command penalty. If exit_code > 0 and known (non-empty),
# return the penalty multiplier (e.g. 500 = 0.5x). Otherwise return 1000.
# Unknown exit = "" or "0" or any falsy → 1000 (no penalty).
# ---------------------------------------------------------------------------
_smart_x_exit() {
    local exit_code="${1:-0}"
    if [[ -n "$exit_code" ]] && (( exit_code != 0 )) 2>/dev/null; then
        _SMART_SCORE_RET=${_SMART_RANKING_FAILED_PENALTY:-500}
    else
        _SMART_SCORE_RET=1000
    fi
}
_smart_score_exit() {
    _smart_x_exit "$@"
    print -r -- "$_SMART_SCORE_RET"
}

# ---------------------------------------------------------------------------
# _smart_score_total <prefix> <cmd> <freq> <rec> <max_freq> <max_rec>
#                     [cmd_cwd] [current_cwd]
#                     [cmd_host] [current_host]
#                     [cmd_exit] → 0..1000
#
# Convenience: compute all sub-scores + weighted + chained multipliers.
# v0.1.3: params 7-8 = CWD.
# v0.2.0: params 9-11 = host (cmd_host, current_host) + exit (cmd_exit).
#         All params after 6 are optional; empty = skip that multiplier.
# ---------------------------------------------------------------------------
# Internal variant: store result in _SMART_SCORE_RET (no subshell).
_smart_x_total() {
    local prefix="$1" cmd="$2" freq="$3" rec="$4" max_freq="$5" max_rec="$6"
    local cmd_cwd="${7:-}" current_cwd="${8:-}"
    local cmd_host="${9:-}" current_host="${10:-}"
    local cmd_exit="${11:-}"

    local p r f
    _smart_x_prefix    "$prefix" "$cmd";      p=$_SMART_SCORE_RET
    _smart_x_recency   "$rec"    "$max_rec";  r=$_SMART_SCORE_RET
    _smart_x_frequency "$freq"   "$max_freq"; f=$_SMART_SCORE_RET

    local weighted=$(( _SMART_W_PREFIX * p + _SMART_W_RECENCY * r + _SMART_W_FREQ * f ))
    local wsum=$(( _SMART_W_PREFIX + _SMART_W_RECENCY + _SMART_W_FREQ ))
    (( wsum == 0 )) && wsum=1000
    local final=$(( weighted / wsum ))

    # Chained multipliers (all milli-units → divide by 1000).
    if [[ -n "$cmd_cwd" && -n "$current_cwd" ]]; then
        _smart_x_cwd "$cmd_cwd" "$current_cwd"
        final=$(( final * _SMART_SCORE_RET / 1000 ))
    fi
    if [[ -n "$cmd_host" && -n "$current_host" ]]; then
        _smart_x_host "$cmd_host" "$current_host"
        final=$(( final * _SMART_SCORE_RET / 1000 ))
    fi
    if [[ -n "$cmd_exit" ]]; then
        _smart_x_exit "$cmd_exit"
        final=$(( final * _SMART_SCORE_RET / 1000 ))
    fi

    (( final < 0 )) && final=0
    (( final > 1000 )) && final=1000
    _SMART_SCORE_RET=$final
}

_smart_score_total() {
    _smart_x_total "$@"
    print -r -- "$_SMART_SCORE_RET"
}

# ---------------------------------------------------------------------------
# _smart_fmt_score <milli> — 823 -> "0.823"
# ---------------------------------------------------------------------------
_smart_fmt_score() {
    local m="${1:-0}"
    (( m < 0 )) && m=0
    (( m > 1000 )) && m=1000
    printf '%d.%03d' $(( m / 1000 )) $(( m % 1000 ))
}
