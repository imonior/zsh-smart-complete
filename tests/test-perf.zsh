#!/usr/bin/env zsh
# tests/test-perf.zsh
#
# Performance regression guards for the two index operations that run while the
# user is typing, i.e. the ones where a complexity mistake is felt as a stall:
#
#   * _smart_state_l_set history.cmds  -- the rebuild write, which also
#     rebuilds the first-char buckets (_smart_cmds_rebucket).
#   * _smart_history_upsert            -- once per Enter.
#   * _smart_history_iter_prefix       -- once per keystroke that shows a popup.
#
# Why timings and not just behaviour: every one of these was quadratic at some
# point, and each time the output stayed perfectly correct — the only symptom
# was a 20-second rebuild. A behavioural test cannot catch that, so this file
# asserts on wall clock instead.
#
# How the numbers are chosen: measured on the reference index (13 distinct
# verbs, so ~n/13 entries per bucket) on an 8 GB laptop, best of several runs,
# then given 5-8x headroom. Caps are deliberately loose — they are tripwires
# for a complexity change (which costs 2x per doubling of n), not for a noisy CI
# box. Each PASS line prints the measured time so a slow drift is visible in
# the log before it ever crosses a cap.

emulate -L zsh
setopt extended_glob no_warn_create_global
ROOT="${0:a:h:h}"
PASS=0
FAIL=0

zmodload zsh/datetime 2>/dev/null || {
    print -r -- "=== SKIP: zsh/datetime unavailable, cannot time anything ==="
    exit 0
}

# ELAPSED_US holds the fastest of <reps> runs of the given command, in
# microseconds (best-of, because a single GC or scheduler hiccup on a CI box
# must not fail a cap; the EPOCHREALTIME arithmetic stays a float until the
# final division).
ELAPSED_US=0
timed() {
    local reps="$1" best=999999999999 t0 t1 d r
    shift
    for (( r = 0; r < reps; r++ )); do
        (( t0 = EPOCHREALTIME ))
        "$@"
        (( t1 = EPOCHREALTIME ))
        (( d = (t1 - t0) * 1000000 ))
        (( d < best )) && best=$d
    done
    ELAPSED_US=$best
}

assert_fast() {
    local name="$1" cap_ms="$2"
    if (( ELAPSED_US < cap_ms * 1000 )); then
        (( PASS++ ))
        printf '  PASS  %s  %.1f ms (cap %s ms)\n' "$name" $(( ELAPSED_US / 1000.0 )) "$cap_ms"
    else
        (( FAIL++ ))
        printf '  FAIL  %s  %.1f ms (cap %s ms)\n' "$name" $(( ELAPSED_US / 1000.0 )) "$cap_ms" >&2
    fi
}

# Scaling check: doubling-size-to-quadruple-size must not cost more than a
# small multiple. A linear implementation measures ~4.0 here; the quadratic one
# this file exists to keep out measured 16-25.
assert_scaling() {
    local name="$1" max_ratio="$2" big_us="$3" small_us="$4"
    if (( small_us < 2000 )); then
        (( PASS++ ))
        printf '  PASS  %s  skipped (base sample %.1f ms is too small to ratio)\n' \
            "$name" $(( small_us / 1000.0 ))
        return 0
    fi
    local ratio=$(( big_us * 1.0 / small_us ))
    if (( ratio < max_ratio )); then
        (( PASS++ ))
        printf '  PASS  %s  4x size cost %.1fx (max %sx)\n' "$name" "$ratio" "$max_ratio"
    else
        (( FAIL++ ))
        printf '  FAIL  %s  4x size cost %.1fx (max %sx)\n' "$name" "$ratio" "$max_ratio" >&2
    fi
}

source "${ROOT}/lib/config.zsh"
source "${ROOT}/lib/state.zsh"
source "${ROOT}/lib/history/history.zsh"

# ---------------------------------------------------------------------------
# Synthetic index, shaped like a real one: many first characters, so that
# bucket-bound work and full-array work can be told apart. A single-verb corpus
# would hide an O(n) bucket scan behind an O(n) everything else.
CMDS=()
_gen_cmds() {
    local n="$1" i
    local -a verbs=(git docker npm ls cat vim ssh kubectl make cargo python node curl)
    CMDS=()
    for (( i = 1; i <= n; i++ )); do
        CMDS+=("${verbs[i % ${#verbs}]} sub$i -x")
    done
}

_cb() { return 0 }

_small=4000
_big=16000

print -r -- "=== 1. rebuild write + bucket build (_smart_state_l_set) ==="
_gen_cmds $_small
timed 3 _smart_state_l_set history.cmds "${CMDS[@]}"
_small_lset=$ELAPSED_US
assert_fast "l_set history.cmds at ${_small} commands" 250
_gen_cmds $_big
timed 3 _smart_state_l_set history.cmds "${CMDS[@]}"
_big_lset=$ELAPSED_US
assert_fast "l_set history.cmds at ${_big} commands" 500
assert_scaling "l_set: 4x the index" 6 "$_big_lset" "$_small_lset"

print -r -- ""
print -r -- "=== 2. per-Enter upsert (existing command, old bucket position) ==="
# The commands are picked from deep inside the index on purpose: the common
# Enter repeats the previous command, which is already at its bucket head and
# costs nothing. This is the path a bucket rebuild has to pay for.
_gen_cmds $_big
_smart_state_l_set history.cmds "${CMDS[@]}"
_do_upserts() {
    local i step=$(( ${#CMDS[@]} / 60 ))
    for (( i = 1; i <= 50; i++ )); do
        _smart_history_upsert "${CMDS[i * step]}" ""
    done
}
timed 3 _do_upserts
_big_up=$ELAPSED_US
assert_fast "50 upserts over a ${_big} command index" 500
_gen_cmds $_small
_smart_state_l_set history.cmds "${CMDS[@]}"
timed 3 _do_upserts
_small_up=$ELAPSED_US
assert_scaling "upsert: 4x the index" 8 "$_big_up" "$_small_up"

print -r -- ""
print -r -- "=== 3. per-keystroke prefix iteration ==="
# The scan is bounded by the candidate's bucket, not by the index: 4x the index
# means 4x per bucket (the corpus keeps the verb count fixed), and that is the
# growth this checks for. The absolute cap is the one that matters — a
# full-index scan costs ~2.6 microseconds per command in zsh, i.e. ~40 ms per
# keystroke at 16k, which is what this index was built to avoid.
_gen_cmds $_small
_smart_state_l_set history.cmds "${CMDS[@]}"
_do_iter() {
    local i
    for (( i = 0; i < 20; i++ )); do
        _smart_history_iter_prefix "git " 10 _cb
    done
}
timed 3 _do_iter
_small_iter=$ELAPSED_US
assert_fast "20 prefix iterations over a ${_small} command index" 400
_gen_cmds $_big
_smart_state_l_set history.cmds "${CMDS[@]}"
timed 3 _do_iter
assert_fast "20 prefix iterations over a ${_big} command index" 400
assert_scaling "prefix iteration: 4x the index" 6 "$ELAPSED_US" "$_small_iter"

print -r -- ""
print -r -- "=== 4. new distinct command at the cap ==="
# With the periodic rebuild disabled the index caps itself, so every new
# command evicts the oldest. That eviction must not copy the array.
_gen_cmds $_big
_smart_state_l_set history.cmds "${CMDS[@]}"
SMART_SUGGEST_HISTORY_LIMIT=$_big
_do_new() {
    local i
    for (( i = 1; i <= 100; i++ )); do
        _smart_history_upsert "zz new$i --flag"
    done
}
timed 2 _do_new
assert_fast "100 new commands at a ${_big} cap" 500
if (( ${#_SMART_CMDS[@]} <= _big )); then
    (( PASS++ ))
    print -r -- "  PASS  index stayed capped at ${#_SMART_CMDS[@]} <= ${_big}"
else
    (( FAIL++ ))
    print -r -- "  FAIL  cap did not hold: ${#_SMART_CMDS[@]} > ${_big}" >&2
fi

print -r -- ""
print -r -- "=== 5. command-position test on the keystroke path ==="
# lib/engine/menu.zsh widened `_smart_menu_is_command_word` from "is this the
# first word" to "is this a position where the shell still picks a command"
# (after `|`, `&&`, `;`, or a wrapper like `sudo`), and the popup calls it on
# every keystroke. The widening is worth exactly nothing if it costs more than
# the completion it is deciding whether to run, so the claim in that function's
# comment is asserted here instead of trusted: ~10 microseconds per call on a
# realistic line, and linear — not quadratic — in the length of that line.
source "${ROOT}/lib/engine/menu.zsh"
_short_line="git log --on"
_long_line=""
for (( i = 1; i <= 20; i++ )); do _long_line+="echo word$i arg$i "; done
_long_line+="git che"
_check_short() {
    local i
    LBUFFER="$_short_line"
    for (( i = 0; i < 200; i++ )); do _smart_menu_is_command_word; done
}
_check_long() {
    local i
    LBUFFER="$_long_line"
    for (( i = 0; i < 200; i++ )); do _smart_menu_is_command_word; done
}
timed 3 _check_short
_short_pos=$ELAPSED_US
assert_fast "200 command-position tests, 2-word line" 12
printf '  INFO  %.2f us per call (short line)\n' $(( _short_pos / 200.0 ))
timed 3 _check_long
assert_fast "200 command-position tests, ${#_long_line}-char line" 40
assert_scaling "command position: ${#_long_line}/${#_short_line} chars costs less than 16x" \
    16 "$ELAPSED_US" "$_short_pos"

print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
