#!/usr/bin/env zsh
# tests/test-suggest.zsh
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
assert_ge() {
    local name="$1" got="$2" min="$3"
    if (( got >= min )); then
        (( PASS++ ))
        print -r -- "  PASS  $name  ($got >= $min)"
    else
        (( FAIL++ ))
        print -r -- "  FAIL  $name  got=$got want>=$min" >&2
    fi
}

source "${ROOT}/lib/config.zsh"
source "${ROOT}/lib/state.zsh"
source "${ROOT}/lib/history/history.zsh"
source "${ROOT}/lib/engine/ranking.zsh"
source "${ROOT}/lib/engine/suggest.zsh"

score_milli() {
    local s="$1" int frac
    int="${s%%.*}"
    frac="${s#*.}"
    printf '%d' $(( int * 1000 + 10#${frac:-0} ))
}

inject() {
    _smart_state_a_unset_sub "history.frequency"
    _smart_state_a_unset_sub "history.recency"
    local -a order=("git status" "git checkout main" "git checkout develop"
        "git pull" "docker compose up -d" "docker ps" "docker compose down"
        "ls -la" "cd ~" "cargo build")
    local -A freq=(["git status"]=8 ["git checkout main"]=5
        ["git checkout develop"]=2 ["git pull"]=1 ["docker compose up -d"]=6
        ["docker ps"]=3 ["docker compose down"]=1 ["ls -la"]=15
        ["cd ~"]=4 ["cargo build"]=2)
    local rec=0 max_freq=0 c
    for c in "${order[@]}"; do
        _smart_state_a_set history.recency "$c" "$rec"
        (( rec++ ))
        (( freq[$c] > max_freq )) && max_freq=${freq[$c]}
        _smart_state_a_set history.frequency "$c" "${freq[$c]}"
    done
    _smart_state_l_set history.cmds "${order[@]}"
    _smart_state_set history.count "${#order}"
    _smart_state_set history.max_freq "$max_freq"
    _smart_state_set history.max_recency "$(( rec - 1 ))"
}

print -r -- "=== 场景 1: 'git s' → git status ==="
inject
_smart_suggest_compute "git s"
assert_eq "winner=git status"     "$(_smart_state_get suggestion.text)"   "git status"
assert_eq "source=history"        "$(_smart_state_get suggestion.source)" "history"
assert_ge "score ≥400"            "$(score_milli "$(_smart_state_get suggestion.score)")" 400

print -r -- ""
print -r -- "=== 场景 2: 'docker compose up' → docker compose up -d ==="
inject
_smart_suggest_compute "docker compose up"
assert_eq "winner=compose up -d"  "$(_smart_state_get suggestion.text)"   "docker compose up -d"
assert_ge "score ≥700"            "$(score_milli "$(_smart_state_get suggestion.score)")" 700

print -r -- ""
print -r -- "=== 场景 3: 'git checkout' → main（更新 且 高频）==="
inject
_smart_suggest_compute "git checkout"
assert_eq "winner=main"           "$(_smart_state_get suggestion.text)"   "git checkout main"

print -r -- ""
print -r -- "=== 场景 4: 空 BUFFER → 空 ==="
inject
_smart_suggest_compute ""
assert_eq "no text"               "$(_smart_state_get suggestion.text)"   ""
assert_eq "no source"             "$(_smart_state_get suggestion.source)" ""

print -r -- ""
print -r -- "=== 场景 5: exact-only (git pull 无更长扩展) ==="
inject
_smart_suggest_compute "git pull"
assert_eq "exact → empty text"    "$(_smart_state_get suggestion.text)"   ""

print -r -- ""
print -r -- "=== 场景 6: SMART_SUGGEST=false 不计算 ==="
inject
SMART_SUGGEST=false
_smart_suggest_compute "git s"
SMART_SUGGEST=true
assert_eq "flag off→no text"      "$(_smart_state_get suggestion.text)"   ""
assert_eq "flag off→no source"    "$(_smart_state_get suggestion.source)" ""

print -r -- ""
print -r -- "=== 场景 7: enabled=0 不计算 ==="
inject
_smart_state_set enabled 0
_smart_suggest_compute "git s"
_smart_state_set enabled 1
assert_eq "state off→empty text"  "$(_smart_state_get suggestion.text)"   ""

print -r -- ""
print -r -- "=== 场景 8: _smart_suggest_get_text ==="
inject
local txt=$(_smart_suggest_get_text "ls -")
assert_eq "get_text ls - → ls -la" "$txt" "ls -la"

print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
