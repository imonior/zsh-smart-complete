#!/usr/bin/env zsh
# tests/test-history.zsh
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

source "${ROOT}/lib/config.zsh"
source "${ROOT}/lib/state.zsh"
source "${ROOT}/lib/history/history.zsh"

inject_history() {
    _smart_state_a_unset_sub "history.frequency"
    _smart_state_a_unset_sub "history.recency"
    local -a order=()
    local -A freq=() seen=()
    local rec=0 max_freq=0 cmd
    for cmd in "$@"; do
        if [[ -z "${seen[$cmd]}" ]]; then
            seen[$cmd]=1
            order+=("$cmd")
            freq[$cmd]=1
            _smart_state_a_set history.recency "$cmd" "$rec"
            (( rec++ ))
        else
            freq[$cmd]=$(( freq[$cmd] + 1 ))
        fi
        (( freq[$cmd] > max_freq )) && max_freq=${freq[$cmd]}
    done
    local c
    for c in "${order[@]}"; do
        _smart_state_a_set history.frequency "$c" "${freq[$c]}"
    done
    _smart_state_l_set history.cmds "${order[@]}"
    _smart_state_set history.count "${#order}"
    _smart_state_set history.max_freq "$max_freq"
    _smart_state_set history.max_recency "$(( rec > 0 ? rec - 1 : 0 ))"
    _smart_state_set history.rebuilt_at 1700000000
}

_collect_cb() {
    COLLECT+=("$1|f=$2|r=$3")
    return 0
}

print -r -- "=== 场景 1: 索引基础 ==="
inject_history \
    "git status" "git status" "git status" \
    "git pull" \
    "git checkout main" "git checkout main" \
    "git checkout develop" \
    "docker ps" \
    "docker compose up -d" "docker compose up -d" "docker compose up -d" "docker compose up -d" \
    "docker compose down"
assert_eq "distinct=7"                   "$(_smart_state_get history.count)"    "7"
assert_eq "max_freq=4"                   "$(_smart_state_get history.max_freq)" "4"
assert_eq "rec(git status)=0"            "$(_smart_state_a_get history.recency "git status")" "0"
assert_eq "freq(docker compose up -d)=4" "$(_smart_state_a_get history.frequency "docker compose up -d")" "4"
assert_eq "freq(git pull)=1"             "$(_smart_state_a_get history.frequency "git pull")" "1"

print -r -- ""
print -r -- "=== 场景 2: 'git ' 前缀迭代 ==="
COLLECT=()
_smart_history_iter_prefix "git " 10 _collect_cb
assert_eq "prefix git count=4"       "${#COLLECT}" "4"
assert_eq "  [1]=git status"         "${COLLECT[1]%%\|*}"   "git status"
assert_eq "  [2]=git pull"           "${COLLECT[2]%%\|*}"   "git pull"
assert_eq "  [3]=git checkout main"  "${COLLECT[3]%%\|*}"   "git checkout main"
assert_eq "  [4]=git checkout dev"   "${COLLECT[4]%%\|*}"   "git checkout develop"

print -r -- ""
print -r -- "=== 场景 3: N=2 截断 ==="
COLLECT=()
_smart_history_iter_prefix "docker " 2 _collect_cb
assert_eq "docker N=2 count=2"       "${#COLLECT}" "2"

print -r -- ""
print -r -- "=== 场景 4: exact=输入本身 过滤 ==="
COLLECT=()
_smart_history_iter_prefix "git status" 5 _collect_cb
assert_eq "exact git status → 0"     "${#COLLECT}" "0"

print -r -- ""
print -r -- "=== 场景 5: 不匹配前缀 ==="
COLLECT=()
_smart_history_iter_prefix "xyz_nope" 5 _collect_cb
assert_eq "no match → 0"             "${#COLLECT}" "0"

print -r -- ""
print -r -- "=== 场景 6: 'git checkout ' → main first（更新）==="
COLLECT=()
_smart_history_iter_prefix "git checkout " 5 _collect_cb
assert_eq "count=2"                     "${#COLLECT}"                     "2"
assert_eq "1st = main"                  "${COLLECT[1]%%\|*}"             "git checkout main"
assert_eq "2nd = develop"               "${COLLECT[2]%%\|*}"             "git checkout develop"
# order of FIRST-OCCURRENCE in the inject argument list (with duplicates):
#  0 git status   1 git pull   2 git checkout main   3 git checkout develop  ...
assert_eq "main rec=2"                   "${${COLLECT[1]##*r=}}"          "2"
assert_eq "develop rec=3"                "${${COLLECT[2]##*r=}}"          "3"

print -r -- ""
print -r -- "=== 场景 7: new_since 未达阈值不重建 ==="
_smart_state_set history.new_since 0
SMART_HISTORY_REBUILD_EVERY=3
_smart_history_on_new_command
_smart_history_on_new_command
assert_eq "after 2 cmds new_since=2" "$(_smart_state_get history.new_since)" "2"
assert_eq "count stays 7"            "$(_smart_state_get history.count)"     "7"

print -r -- ""
print -r -- "=== 场景 8: 达到阈值触发重建（非交互 fc → 数字合法） ==="
_smart_history_on_new_command
local c=$(_smart_state_get history.count)
if [[ "$c" =~ '^[0-9]+$' ]]; then
    (( PASS++ ))
    print -r -- "  PASS  rebuilt count numeric: $c"
else
    (( FAIL++ ))
    print -r -- "  FAIL  rebuilt count not numeric: [$c]" >&2
fi

print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
