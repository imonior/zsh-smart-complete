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
    local -A freq=() seen=() rank=()
    local rec=0 max_freq=0 cmd
    for cmd in "$@"; do
        if [[ -z "${seen[$cmd]}" ]]; then
            seen[$cmd]=1
            order+=("$cmd")
            freq[$cmd]=1
            rank[$cmd]=$rec
            (( rec++ ))
        else
            freq[$cmd]=$(( freq[$cmd] + 1 ))
        fi
        (( freq[$cmd] > max_freq )) && max_freq=${freq[$cmd]}
    done
    # history.recency holds a last-use tick, not the rank: stamp
    # tick = base - rank so each command's AGE equals its injected rank and
    # the engine sees exactly the ordering these expectations assume.
    local base=$(( rec > 0 ? rec - 1 : 0 ))
    local c
    for c in "${order[@]}"; do
        _smart_state_a_set history.frequency "$c" "${freq[$c]}"
        _smart_state_a_set history.recency   "$c" "$(( base - rank[$c] ))"
    done
    _smart_state_l_set history.cmds "${order[@]}"
    _smart_state_set history.count "${#order}"
    _smart_state_set history.max_freq "$max_freq"
    _smart_state_set history.max_recency "$base"
    _smart_state_set history.tick "$base"
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
assert_eq "age(git status)=0"            "$(( ${_SMART_STATE[history.tick]} - $(_smart_state_a_get history.recency "git status") ))" "0"
assert_eq "age(docker compose down)=6"   "$(( ${_SMART_STATE[history.tick]} - $(_smart_state_a_get history.recency "docker compose down") ))" "6"
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
print -r -- "=== 场景 6b: upsert 只写一条 recency（tick 模型的核心回归） ==="
# The rank model could not pass this: promoting ANY command shifted every
# later rank, so one Enter rewrote the whole associative map. Under the tick
# model an upsert stamps exactly one command; every other stored tick must be
# byte-identical afterwards.
_st_git=$(_smart_state_a_get history.recency "git status")
_st_docker=$(_smart_state_a_get history.recency "docker ps")
_st_tick=${_SMART_STATE[history.tick]}
_smart_history_upsert "git status"
_now_t=${_SMART_STATE[history.tick]}
assert_eq "tick advanced by exactly 1"   "$(( _now_t - _st_tick ))" "1"
assert_eq "git status age is now 0"      "$(( _now_t - $(_smart_state_a_get history.recency "git status") ))" "0"
assert_eq "untouched command keeps its stored tick" \
    "$(_smart_state_a_get history.recency "docker ps")" "$_st_docker"
# freq bump happened on the same path
assert_eq "freq(git status)=4"           "$(_smart_state_a_get history.frequency "git status")" "4"

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
print -r -- "=== 场景 9: 回归——循环内 local 声明不得向 stdout 泄漏（ZLE 终端污染） ==="
# 背景: zsh 5.9 下,在 for 循环体内 `local key` 且循环内调用回调函数,
# 会把变量值以 `key='…'` 形式泄漏到 stdout。ZLE 组件中 stdout 直达终端,
# 曾导致每次按键向终端打印 `key='history.recency|…'` 垃圾行。
# 修复: `key` 的 local 声明移到循环外。此测试在 $() 中跑迭代器,断言无输出。
_smart_state_reset
_smart_state_l_set history.cmds "git status" "git pull" "git checkout main" "git checkout develop"
_smart_state_set history.count 4
COLLECT=()
_smart_collect_cb() { COLLECT+=("$1"); return 0; }
# 注意: 不能把迭代器放进 $() —— 子 shell 会让回调的 COLLECT 写不回主进程。
# 直接执行并把 stdout 重定向到文件,同样能捕获 fd 层面的泄漏。
_leak_file="${TMPDIR:-/tmp}/zsc_iter_leak.$$_$RANDOM"
_smart_history_iter_prefix "git" 10 _smart_collect_cb > "$_leak_file" 2>&1
leaked="$(cat "$_leak_file" 2>/dev/null)"
rm -f "$_leak_file"
assert_eq "迭代器 stdout 干净(无 key= 泄漏)" "$leaked" ""
assert_eq "回调调用次数=4"                   "${#COLLECT}" "4"

print -r -- ""
print -r -- "=== 场景 10: 回归——历史行的文本不得被当作算术表达式求值 ==="
# 背景: 后端原先写的是 `(( _SMART_BUILD_FREQ[$cmd] > max_freq ))`，而 zsh 在算术
# 上下文里会把下标内容再当一次表达式求值。$cmd 是用户的一整行历史，于是:
#   * 含 `$(...)` 的历史行在建索引时被真的执行;
#   * 含不成对 `]` 的历史行让算术求值报错、整个 while 中断，而所有调用点都带
#     2>/dev/null，所以现场只剩一个 0 条目的索引。0 条目又让 bootstrap 永远走不到
#     _smart_event_bind，行内灰色提示因此完全不出现。
#     （实测于一台 Ubuntu: zsh 5.9、912 行历史、history.count=0、每次 precmd 挂起。）
# 修复: 计数先取进标量，再进算术上下文。
# 为什么这样测: 场景 8 只做数字合法性检查、而且没有 source 后端文件，所以它调用的是
# 一个不存在的函数——真正读历史的那段循环从来不在覆盖范围内。这里用 fc -R 把敌意行
# 喂进真的后端，是这条路径唯一可复现的入口。
# 挡不住什么: 只有前两条(未执行、stderr 干净)钉住机制,在未修复的代码上实测双双失败;
# 后面几条锁的是修复后 dedup/freq/max 不变,它们在同一缺陷下也可能通过——历史内容不同,
# 这条算术错误落的位置就不同(用户机器上是 precmd 直接挂住,这里是报错后继续)。
# 也不验证 20000 行规模的耗时(另有性能场景),不验证 atuin 后端(它的同处已一并修掉)。
# 成本: 一个临时历史文件 + 一次重建，毫秒级。
# 撤回: 删掉本场景即可;run-all 自动发现套件，无其他文件引用它。
_HDIR="${TMPDIR:-/tmp}/zsc_hist_math.$$_$RANDOM"
_MARK="${_HDIR}/executed-marker"
_ERRF="${_HDIR}/stderr"
mkdir -p "$_HDIR"
# 第一行与第三行故意重复，用来同时验证去重与 freq 累加（原先也走算术下标）。
{
    print -r -- 'git status'
    print -r -- 'print "x ] ( ; while :; do :; done"'
    print -r -- "echo \$(touch ${_MARK})"
    print -r -- 'git status'
} > "${_HDIR}/history"

source "${ROOT}/lib/history/zsh.zsh"
_smart_state_reset
fc -R "${_HDIR}/history"
SMART_SUGGEST_HISTORY_LIMIT=100 _smart_history_rebuild 2>"$_ERRF"
assert_eq "历史行里的 \$(...) 没有被执行" \
    "$([[ -e "$_MARK" ]] && echo yes || echo no)" "no"
assert_eq "重建过程 stderr 干净(无 bad math expression)" \
    "$(wc -c < "$_ERRF" | tr -d ' ')" "0"
assert_eq "敌意行全部入索引(去重后 3 条)"  "$(_smart_state_get history.count)"    "3"
assert_eq "重复行 freq 累加"              "$(_smart_state_a_get history.frequency "git status")" "2"
assert_eq "最大 freq 正确"                "$(_smart_state_get history.max_freq)" "2"
assert_eq "不成对 ] 的那行按字符串存住"    \
    "$(_smart_state_a_get history.frequency 'print "x ] ( ; while :; do :; done"')" "1"
rm -rf "$_HDIR"

print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
