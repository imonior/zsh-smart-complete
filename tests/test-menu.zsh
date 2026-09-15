#!/usr/bin/env zsh
# tests/test-menu.zsh
#
# Unit tests for the type-to-popup candidate menu (lib/engine/menu.zsh) and the
# partial-accept path in lib/display/display.zsh.
#
# Verifies:
#   * the module loads and exposes its public surface
#   * the gating rules (kill switch, command-word vs argument-word prefix,
#     empty word, over-long word)
#   * the wall clock used for throttling is actually available
#     (regression: zsh/datetime must be requested with `p:`, not `b:`)
#   * terminfo is loaded as a PARAMETER (same class of regression)
#   * alt+right partial accept walks exactly one word
#   * smart-menu on/off/status round-trip
#
# NOTE: these run OUTSIDE an interactive ZLE context, so they exercise the pure
# logic. The on-screen behaviour (list actually painted, keys really accepted)
# is proven by the pty/tmux harness, not here.

emulate -L zsh
setopt extended_glob no_warn_create_global
ROOT="${0:a:h:h}"
PASS=0
FAIL=0

assert_eq() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        (( PASS++ )); print -r -- "  PASS  $name"
    else
        (( FAIL++ )); print -r -- "  FAIL  $name  got=[$got] want=[$want]" >&2
    fi
}

assert_rc() {
    local name="$1" want="$2"; shift 2
    "$@" >/dev/null 2>&1
    local got=$?
    if [[ "$got" == "$want" ]]; then
        (( PASS++ )); print -r -- "  PASS  $name"
    else
        (( FAIL++ )); print -r -- "  FAIL  $name  rc=$got want=$want" >&2
    fi
}

assert_fn_exists() {
    if (( ${+functions[$1]} )); then
        (( PASS++ )); print -r -- "  PASS  function $1 exists"
    else
        (( FAIL++ )); print -r -- "  FAIL  function $1 missing" >&2
    fi
}

source "${ROOT}/lib/config.zsh"
source "${ROOT}/lib/state.zsh"
source "${ROOT}/lib/engine/native.zsh"
source "${ROOT}/lib/engine/menu.zsh"
source "${ROOT}/lib/display/display.zsh"
# zle.zsh owns _smart_evt_build_seq_lists (the multi-encoding arrow bindings).
source "${ROOT}/lib/event/zle.zsh"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 1: 模块与公开接口存在 ==="
assert_fn_exists _smart_menu_enabled
assert_fn_exists _smart_menu_word
assert_fn_exists _smart_menu_is_command_word
assert_fn_exists _smart_menu_should_list
assert_fn_exists _smart_menu_list_main
assert_fn_exists _smart_menu_tick
assert_fn_exists _smart_menu_clear
assert_fn_exists _smart_display_accept_word
if (( ${+functions[smart-menu]} )); then
    (( PASS++ )); print -r -- "  PASS  smart-menu CLI exists"
else
    (( FAIL++ )); print -r -- "  FAIL  smart-menu CLI missing" >&2
fi

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 2: 配置项默认值 ==="
assert_eq "SMART_MENU default is true"      "${SMART_MENU}"             "true"
assert_eq "SMART_MENU_MIN_PREFIX default"   "${SMART_MENU_MIN_PREFIX}"  "1"
assert_eq "SMART_MENU_MIN_PREFIX_CMD"       "${SMART_MENU_MIN_PREFIX_CMD}" "2"
assert_eq "SMART_MENU_MIN_MATCHES default"  "${SMART_MENU_MIN_MATCHES}" "2"
# The throttle is OFF by default: every ordinary listing measures 10-30ms, and
# the only spike is a one-off ~180ms cold load. Throttling that removed the
# popup from the first `git <TAB>` of a session, which is the reported bug.
assert_eq "SMART_MENU_SLOW_MS default"      "${SMART_MENU_SLOW_MS}"     "250"
assert_eq "SMART_MENU_COOLDOWN_KEYS default is off" "${SMART_MENU_COOLDOWN_KEYS}" "0"
# The debug trace must be a documented, inert-by-default knob.
assert_eq "SMART_MENU_DEBUG default is empty" "${SMART_MENU_DEBUG}" ""

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 3: 墙壁时钟可用（回归：zsh/datetime 必须用 p: 前缀）==="
# `zmodload -F zsh/datetime b:EPOCHREALTIME` is rejected ("no such feature")
# and leaves $EPOCHREALTIME undefined, which silently disables all throttling.
assert_rc "clock is available" 0 _smart_menu_have_clock
local t1 t2
t1=$(_smart_menu_now_ms)
sleep 0.05
t2=$(_smart_menu_now_ms)
if [[ "$t1" == <-> ]] && (( t2 > t1 )); then
    (( PASS++ )); print -r -- "  PASS  _smart_menu_now_ms advances ($t1 -> $t2)"
else
    (( FAIL++ )); print -r -- "  FAIL  _smart_menu_now_ms did not advance: [$t1] -> [$t2]" >&2
fi

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 4: terminfo 作为参数加载（回归：p:terminfo）==="
# Same failure class as the clock: b:terminfo is rejected, so the right-arrow
# sequence reported by the terminal would never be bound.
_smart_evt_build_seq_lists 2>/dev/null
if (( ${+parameters[terminfo]} )); then
    (( PASS++ )); print -r -- "  PASS  \$terminfo parameter is loaded"
else
    (( FAIL++ )); print -r -- "  FAIL  \$terminfo parameter missing (wrong zmodload feature prefix)" >&2
fi
if (( ${#_SMART_EVT_FWD_SEQS} >= 2 )); then
    (( PASS++ )); print -r -- "  PASS  forward-arrow sequence list built (${#_SMART_EVT_FWD_SEQS} forms)"
else
    (( FAIL++ )); print -r -- "  FAIL  forward-arrow sequence list too short: ${#_SMART_EVT_FWD_SEQS}" >&2
fi
local seq found_csi found_ss3
found_csi=0; found_ss3=0
for seq in "${_SMART_EVT_FWD_SEQS[@]}"; do
    [[ "$seq" == '^[[C' || "$seq" == $'\e[C' ]] && found_csi=1
    [[ "$seq" == '^[OC' || "$seq" == $'\eOC' ]] && found_ss3=1
done
assert_eq "CSI form (ESC [ C) present" "$found_csi" "1"
assert_eq "SS3 form (ESC O C) present — the one TERM=xterm-256color sends" "$found_ss3" "1"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 4b: 节流策略（回归：默认不得吞掉弹窗）==="
# The bug this guards: the throttle used to default to 50ms / 3 edits. A cold
# shell's first `git <TAB>` costs ~180ms (one-off load of git's completions), so
# the very next keystrokes were skipped — and because a skipped edit also drops
# whatever list was on screen, the popup vanished for the first word typed in a
# session. Policy must therefore be: OFF by default, and when enabled it must
# only arm on a cost that really is at/above the threshold.
_assert_cooldown() {  # name, cost, want_cooldown
    _SMART_MENU_COOLDOWN=0
    _smart_menu_note_cost "$2"
    assert_eq "$1 (cost=${2}ms)" "$_SMART_MENU_COOLDOWN" "$3"
}

assert_eq "throttle off by default" "${SMART_MENU_COOLDOWN_KEYS}" "0"
_assert_cooldown "cooldown off: 180ms spike does not arm" 180 "0"
_assert_cooldown "cooldown off: 900ms does not arm either" 900 "0"
assert_eq "cost is still recorded when throttling is off" "$_SMART_MENU_LAST_MS" "900"

# Now enable it and check the boundary.
SMART_MENU_COOLDOWN_KEYS=2
SMART_MENU_SLOW_MS=250
_assert_cooldown "enabled: 10ms (ordinary listing) does not arm" 10 "0"
_assert_cooldown "enabled: 180ms cold load does not arm" 180 "0"
_assert_cooldown "enabled: exactly 250ms arms" 250 "2"
_assert_cooldown "enabled: 900ms arms" 900 "2"
SMART_MENU_SLOW_MS=0
_assert_cooldown "SLOW_MS=0 disables arming even when enabled" 9000 "0"
SMART_MENU_SLOW_MS=250
SMART_MENU_COOLDOWN_KEYS=0

# The debug knob must be inert unless a path is given.
SMART_MENU_DEBUG=""
assert_eq "debug trace writes nothing when unset" "$(_smart_menu_dbg 'x' 2>&1)" ""
# (The "a skipped tick consumes one cooldown" case lives at the end of the file,
#  because it has to stub the gate function, which later scenarios rely on.)

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 5: 分段（gate）规则 ==="
SMART_MENU=true
_smart_state_set enabled 1
# compinit is absent in this test shell, so should_list must refuse — that is
# the documented no-op behaviour when the user never ran compinit.
assert_rc "no compinit -> never list" 1 _smart_menu_should_list

# Fake a working compinit so we can exercise the prefix rules.
_smart_native_have_compinit() { return 0 }

LBUFFER="g"
assert_rc "command word, 1 char -> do not list" 1 _smart_menu_should_list
LBUFFER="gi"
assert_rc "command word, 2 chars -> list" 0 _smart_menu_should_list
LBUFFER="git "
assert_rc "empty argument word -> do not list" 1 _smart_menu_should_list
LBUFFER="git s"
assert_rc "argument word, 1 char -> list" 0 _smart_menu_should_list
SMART_MENU_MAX_PREFIX=5
LBUFFER="git status"
assert_rc "word longer than SMART_MENU_MAX_PREFIX -> do not list" 1 _smart_menu_should_list
LBUFFER="git st"
assert_rc "word at SMART_MENU_MAX_PREFIX -> still lists" 0 _smart_menu_should_list
SMART_MENU_MAX_PREFIX=64
SMART_MENU_MIN_PREFIX=0
LBUFFER="git "
assert_rc "MIN_PREFIX=0 -> list on an empty word too" 0 _smart_menu_should_list
SMART_MENU_MIN_PREFIX=1

SMART_MENU=false
LBUFFER="git s"
assert_rc "SMART_MENU=false -> never list" 1 _smart_menu_should_list
SMART_MENU=true
_smart_state_set enabled 0
assert_rc "runtime disabled -> never list" 1 _smart_menu_should_list
_smart_state_set enabled 1

print -r -- ""
print -r -- "=== 场景 6: 词与「是否命令行首词」判定 ==="
LBUFFER="git sw"
assert_eq "word of 'git sw'" "$(_smart_menu_word)" "sw"
LBUFFER="git "
assert_eq "word of 'git ' (empty)" "$(_smart_menu_word)" ""
LBUFFER="gi"
assert_rc "first word is a command word" 0 _smart_menu_is_command_word
LBUFFER="git s"
assert_rc "second word is not a command word" 1 _smart_menu_is_command_word
LBUFFER="  gi"
assert_rc "leading spaces still command word" 0 _smart_menu_is_command_word

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 7: Alt+→ 只接受一个词 ==="
_smart_state_set suggestion.text "git status"
BUFFER="git s"; CURSOR=${#BUFFER}
_smart_display_accept_word 2>/dev/null
assert_eq "accept word: 'git s' + 'tatus' -> full word" "$BUFFER" "git status"

_smart_state_set suggestion.text "docker compose up -d"
BUFFER="docker c"; CURSOR=${#BUFFER}
_smart_display_accept_word 2>/dev/null
assert_eq "accept word keeps the separator" "$BUFFER" "docker compose "

_smart_state_set suggestion.text "git status --short"
BUFFER="git status"; CURSOR=${#BUFFER}
_smart_display_accept_word 2>/dev/null
assert_eq "accept word walks past the leading separator" "$BUFFER" "git status --short"

_smart_state_set suggestion.text "git switch main"
BUFFER="git swit"; CURSOR=${#BUFFER}
_smart_display_accept_word 2>/dev/null
assert_eq "accept word on a partial word" "$BUFFER" "git switch "
assert_eq "cursor lands at end of buffer" "$CURSOR" "${#BUFFER}"

_smart_state_set suggestion.text ""
BUFFER="anything"; CURSOR=${#BUFFER}
assert_rc "no suggestion -> returns 1 (caller falls back)" 1 _smart_display_accept_word
assert_eq "buffer untouched when there is no suggestion" "$BUFFER" "anything"
_smart_state_set suggestion.text "nomatch"
BUFFER="x"; CURSOR=${#BUFFER}
assert_rc "suggestion not extending buffer -> returns 1" 1 _smart_display_accept_word

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 8: smart-menu on/off/status 往返 ==="
smart-menu off >/dev/null
assert_eq "off sets SMART_MENU" "${SMART_MENU}" "false"
LBUFFER="git s"
assert_rc "disabled -> should_list refuses" 1 _smart_menu_should_list
smart-menu on >/dev/null
assert_eq "on restores SMART_MENU" "${SMART_MENU}" "true"
assert_rc "re-enabled -> should_list agrees again" 0 _smart_menu_should_list
unfunction _smart_native_have_compinit 2>/dev/null
assert_rc "should_list refuses once compinit is gone again" 1 _smart_menu_should_list
local st
st=$(smart-menu status 2>&1)
if [[ "$st" == *"smart-menu:"* ]]; then
    (( PASS++ )); print -r -- "  PASS  status prints a summary"
else
    (( FAIL++ )); print -r -- "  FAIL  status output unexpected: [$st]" >&2
fi

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 9: 列表状态簿记 ==="
_SMART_MENU_LISTED=1
_SMART_MENU_NMATCHES=42
_smart_menu_clear
assert_eq "clear resets listed"  "$_SMART_MENU_LISTED"  "0"
assert_eq "clear resets matches" "$_SMART_MENU_NMATCHES" "0"

print -r -- ""
print -r -- "=== 场景 10: 被节流跳过的 tick 会消耗冷却并计数 ==="
# Stubbing the gate is invasive, so it happens last: everything above must see
# the real _smart_menu_should_list.
_smart_state_set enabled 1
SMART_MENU=true
_smart_native_have_compinit() { return 0 }
LBUFFER="git s"
_SMART_MENU_COOLDOWN=2
_SMART_MENU_SKIPS=0
_SMART_MENU_TICKS=0
_smart_menu_tick >/dev/null 2>&1
assert_eq "a skipped tick consumes one cooldown" "$_SMART_MENU_COOLDOWN" "1"
assert_eq "a skipped tick is counted"            "$_SMART_MENU_SKIPS"    "1"
assert_eq "a skipped tick does not run a listing" "$_SMART_MENU_TICKS"   "0"
_SMART_MENU_COOLDOWN=0

# status must say which of the two modes is in force — the whole point is that
# you can tell "no popup" apart from "throttled".
SMART_MENU_COOLDOWN_KEYS=0
if [[ "$(smart-menu status 2>&1)" == *"throttle:                 off"* ]]; then
    (( PASS++ )); print -r -- "  PASS  status reports throttle off"
else
    (( FAIL++ )); print -r -- "  FAIL  status does not report throttle off" >&2
fi
SMART_MENU_COOLDOWN_KEYS=2
if [[ "$(smart-menu status 2>&1)" == *"throttle:                 on"* ]]; then
    (( PASS++ )); print -r -- "  PASS  status reports throttle on"
else
    (( FAIL++ )); print -r -- "  FAIL  status does not report throttle on" >&2
fi
SMART_MENU_COOLDOWN_KEYS=0

print -r -- ""
print -r -- "=== 场景 11: 列表上限 / 「do you wish to see all」提示抑制 ==="
# The live popup must never pop zsh's interactive "do you wish to see all N
# possibilities (M lines)?" confirmation on a huge dir like /bin. That prompt is
# gated by LISTMAX (we scope it to -1 while drawing); and a capped directory is
# suppressed outright by _smart_menu_decide_list, which is unit-tested here.
assert_eq "SMART_MENU_LISTMAX default suppresses the prompt" "${SMART_MENU_LISTMAX}" "-1"
assert_eq "SMART_MENU_MAX_MATCHES default uncapped"          "${SMART_MENU_MAX_MATCHES}" "0"

# _smart_menu_decide_list <nmatches>: 0 = draw, 1 = suppress
local mn="${SMART_MENU_MIN_MATCHES:-2}" mc="${SMART_MENU_MAX_MATCHES:-0}"
SMART_MENU_MIN_MATCHES=2
SMART_MENU_MAX_MATCHES=0
assert_eq "1 match (< MIN_MATCHES) -> suppress"  "$( ( _smart_menu_decide_list 1; print $? ) )" "1"
assert_eq "2 matches (== MIN_MATCHES) -> draw"   "$( ( _smart_menu_decide_list 2; print $? ) )" "0"
assert_eq "50 matches -> draw"                   "$( ( _smart_menu_decide_list 50; print $? ) )" "0"
assert_eq "0 matches -> suppress"                "$( ( _smart_menu_decide_list 0; print $? ) )" "1"

SMART_MENU_MAX_MATCHES=300
assert_eq "cap=300, 300 matches (== cap) -> draw"  "$( ( _smart_menu_decide_list 300; print $? ) )" "0"
assert_eq "cap=300, 301 matches (> cap) -> suppress (huge dir)" "$( ( _smart_menu_decide_list 301; print $? ) )" "1"
assert_eq "cap=300, 1467 matches (/bin) -> suppress"            "$( ( _smart_menu_decide_list 1467; print $? ) )" "1"

SMART_MENU_MAX_MATCHES=0          # restore default (uncapped)
assert_eq "uncapped, 1467 matches -> draw (scrolls, no prompt)"  "$( ( _smart_menu_decide_list 1467; print $? ) )" "0"
SMART_MENU_MIN_MATCHES="$mn"
SMART_MENU_MAX_MATCHES="$mc"

print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
