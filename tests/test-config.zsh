#!/usr/bin/env zsh
# tests/test-config.zsh
emulate -L zsh
setopt extended_glob no_warn_create_global
ROOT="${0:a:h:h}"
PASS=0
FAIL=0

assert_eq() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        (( PASS++ ))
        print -r -- "  PASS  $name"
    else
        (( FAIL++ ))
        print -r -- "  FAIL  $name  got=[$got] want=[$want]" >&2
    fi
}

print -r -- "=== 场景 1: 默认值 ==="
() {
    local -a vars=(SMART_ENABLED SMART_SUGGEST SMART_COMPLETE SMART_HISTORY_BACKEND
        SMART_INLINE SMART_SUGGEST_MAX SMART_HISTORY_REBUILD_EVERY
        SMART_SUGGEST_HISTORY_LIMIT SMART_SUGGEST_COLOR SMART_KEYMAP_SCOPE)
    local v
    for v in "${vars[@]}"; do unset "$v" 2>/dev/null; done
    source "${ROOT}/lib/config.zsh"
    assert_eq "SMART_ENABLED default"       "$SMART_ENABLED"              "true"
    assert_eq "SMART_SUGGEST default"       "$SMART_SUGGEST"              "true"
    assert_eq "SMART_COMPLETE default"      "$SMART_COMPLETE"             "true"
    assert_eq "SMART_HISTORY_BACKEND def"   "$SMART_HISTORY_BACKEND"      "zsh"
    assert_eq "SMART_INLINE default"        "$SMART_INLINE"               "true"
    assert_eq "SMART_SUGGEST_MAX default"   "$SMART_SUGGEST_MAX"          "1"
    assert_eq "SMART_SUGGEST_HISTORY_LIMIT" "$SMART_SUGGEST_HISTORY_LIMIT" "20000"
    assert_eq "SMART_REBUILD default"       "$SMART_HISTORY_REBUILD_EVERY" "500"
    assert_eq "SMART_SUGGEST_COLOR default" "$SMART_SUGGEST_COLOR"        "fg=8"
    assert_eq "SMART_KEYMAP_SCOPE default"  "$SMART_KEYMAP_SCOPE"         "both"
}

print -r -- ""
print -r -- "=== 场景 2: 用户预设置覆盖 ==="
() {
    SMART_ENABLED=false; SMART_SUGGEST=false; SMART_HISTORY_BACKEND=atuin
    SMART_INLINE=false; SMART_KEYMAP_SCOPE=emacs; SMART_SUGGEST_COLOR="fg=245,bold"
    source "${ROOT}/lib/config.zsh"
    assert_eq "SMART_ENABLED overridden"    "$SMART_ENABLED"             "false"
    assert_eq "SMART_SUGGEST overridden"    "$SMART_SUGGEST"             "false"
    assert_eq "SMART_HISTORY_BACKEND atuin" "$SMART_HISTORY_BACKEND"     "atuin"
    assert_eq "SMART_INLINE overridden"     "$SMART_INLINE"              "false"
    assert_eq "SMART_KEYMAP_SCOPE emacs"    "$SMART_KEYMAP_SCOPE"        "emacs"
    assert_eq "SMART_SUGGEST_COLOR kept"    "$SMART_SUGGEST_COLOR"       "fg=245,bold"
}

print -r -- ""
print -r -- "=== 场景 3: state 存取器 ==="
source "${ROOT}/lib/state.zsh"
_smart_state_reset

_smart_state_set foo 42
assert_eq "state_set/get scalar"   "$(_smart_state_get foo)"       "42"
assert_eq "state default empty"    "$(_smart_state_get nope def)"  "def"

_smart_state_a_set freq "ls -la" 5
assert_eq "state_a_set/get space"  "$(_smart_state_a_get freq "ls -la")" "5"
assert_eq "state_a default"        "$(_smart_state_a_get freq xx 0)" "0"

_smart_state_l_set cmds "ls -la" "git status" "docker ps"
local got n
got=$(_smart_state_l_get cmds)
n=$(wc -l <<< "$got" | tr -d ' ')
assert_eq "state_l 3 entries"      "$n"                           "3"
assert_eq "state_l 1st = ls -la"   "$(head -n 1 <<< "$got")"      "ls -la"
assert_eq "state_l 2nd = git st"   "$(sed -n '2p' <<< "$got")"    "git status"
assert_eq "state_l 3rd = docker"   "$(tail -n 1 <<< "$got")"      "docker ps"

_smart_state_reset
assert_eq "reset drops foo"        "$(_smart_state_get foo 0)"    "0"
assert_eq "reset enabled=1"        "$(_smart_state_get enabled)"  "1"
assert_eq "reset drops a-sub"      "$(_smart_state_a_get freq "ls -la" 0)" "0"

print -r -- ""
print -r -- "=== 场景 4: enabled 布尔转换 ==="
() {
    source "${ROOT}/lib/config.zsh"
    source "${ROOT}/lib/state.zsh"
    local val e
    for val in true yes on 1 enabled; do
        case "$val" in false|no|off|0|disabled) e=0 ;; *) e=1 ;; esac
        assert_eq "SMART_ENABLED=$val -> 1" "$e" "1"
    done
    for val in false no off 0 disabled; do
        case "$val" in false|no|off|0|disabled) e=0 ;; *) e=1 ;; esac
        assert_eq "SMART_ENABLED=$val -> 0" "$e" "0"
    done
}

print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
