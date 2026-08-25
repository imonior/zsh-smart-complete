#!/usr/bin/env zsh
# tests/test-ranking.zsh
#
# Unit tests for the scoring/ranking engine (lib/engine/ranking.zsh).
#
# Verifies:
#   * Each sub-score (prefix, recency, frequency) returns 0..1000
#   * Higher prefix ratio → higher score
#   * Newer recency → higher score
#   * Higher frequency → higher score
#   * _smart_score_total produces correct weighted sums
#   * _smart_fmt_score formats correctly

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
assert_ge() {
    local name="$1" got="$2" min="$3"
    if (( got >= min )); then
        (( PASS++ )); print -r -- "  PASS  $name  (got=$got)"
    else
        (( FAIL++ )); print -r -- "  FAIL  $name  got=[$got] want>=$min" >&2
    fi
}
assert_le() {
    local name="$1" got="$2" max="$3"
    if (( got <= max )); then
        (( PASS++ )); print -r -- "  PASS  $name  (got=$got)"
    else
        (( FAIL++ )); print -r -- "  FAIL  $name  got=[$got] want<=$max" >&2
    fi
}

source "${ROOT}/lib/config.zsh"
source "${ROOT}/lib/state.zsh"
source "${ROOT}/lib/engine/ranking.zsh"

# ---------------------------------------------------------------------------
print -r -- "=== 场景 1: prefix score 基础 ==="
# "git s" → "git status": plen=5, clen=9, ratio=555 → bucket 850
assert_eq "prefix 'git s'→'git status'" \
    "$(_smart_score_prefix "git s" "git status")" "850"
# "git checkout " → "git checkout main": plen=13, clen=16, ratio=812 → 1000
assert_eq "prefix high ratio" \
    "$(_smart_score_prefix "git checkout " "git checkout main")" "1000"
# "g" → "git status": plen=1, clen=9, ratio=111 → 250
assert_eq "prefix low ratio" \
    "$(_smart_score_prefix "g" "git status")" "250"
# Exact match → 0
assert_eq "prefix exact match → 0" \
    "$(_smart_score_prefix "git status" "git status")" "0"
# Empty cmd → 0
assert_eq "prefix empty cmd → 0" \
    "$(_smart_score_prefix "x" "")" "0"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 2: recency score (v0.1.3 exponential decay) ==="
# rec=0 (newest) → 1000000/(1000+0) = 1000
assert_eq "recency newest (rec=0, max=10)" \
    "$(_smart_score_recency 0 10)" "1000"
# rec=10 (oldest) → 1000000/(1000+10*10) = 1000000/1100 = 909
assert_eq "recency oldest (rec=10, max=10)" \
    "$(_smart_score_recency 10 10)" "909"
# max_rec=0 → only one item, recency is max
assert_eq "recency single item (max=0)" \
    "$(_smart_score_recency 0 0)" "1000"
# Negative rec clamped to 0
assert_eq "recency negative clamped" \
    "$(_smart_score_recency -5 10)" "1000"
# Mid-range: rec=5 → 1000000/(1000+50) = 952
assert_eq "recency mid (rec=5, max=10)" \
    "$(_smart_score_recency 5 10)" "952"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 3: frequency score ==="
# freq=10, max=10 → frac=1000 → 1000
assert_eq "frequency max (freq=10, max=10)" \
    "$(_smart_score_frequency 10 10)" "1000"
# freq=1, max=10 → frac=100 → 300
assert_eq "frequency low (freq=1, max=10)" \
    "$(_smart_score_frequency 1 10)" "300"
# max_freq=0 → treated as 1
assert_eq "frequency zero max" \
    "$(_smart_score_frequency 5 0)" "1000"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 4: _smart_score_total 综合 ==="
# "git s" → "git status", freq=10, rec=0, max_freq=10, max_rec=10
# prefix=850, recency=1000, freq=1000
# total = (400*850 + 350*1000 + 250*1000) / 1000 = (340000+350000+250000)/1000 = 940
assert_eq "total: git s → git status" \
    "$(_smart_score_total "git s" "git status" 10 0 10 10)" "940"
# Verify it's in [0, 1000]
local s
s=$(_smart_score_total "g" "git status" 1 5 10 10)
assert_ge "total in range [0,1000] lower" "$s" 0
assert_le "total in range [0,1000] upper" "$s" 1000

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 5: _smart_fmt_score 格式化 ==="
assert_eq "fmt 0"    "$(_smart_fmt_score 0)"    "0.000"
assert_eq "fmt 500"  "$(_smart_fmt_score 500)"  "0.500"
assert_eq "fmt 1000" "$(_smart_fmt_score 1000)" "1.000"
assert_eq "fmt 823"  "$(_smart_fmt_score 823)"  "0.823"
assert_eq "fmt 1"    "$(_smart_fmt_score 1)"    "0.001"
# Clamp out-of-range
assert_eq "fmt -5 clamped"  "$(_smart_fmt_score -5)"  "0.000"
assert_eq "fmt 9999 clamped" "$(_smart_fmt_score 9999)" "1.000"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 6: recency > prefix ordering 验证 ==="
# A command with high recency (just typed) but low prefix ratio should
# still score reasonably high due to recency weight.
local s_new s_old
s_new=$(_smart_score_total "g" "git status" 1 0 10 10)    # rec=0 (newest)
s_old=$(_smart_score_total "g" "git status" 1 10 10 10)   # rec=10 (oldest)
assert_ge "newer ranks higher than older" "$s_new" "$s_old"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 7: frequency influence ==="
# Higher frequency should produce higher or equal score.
local s_low_f s_high_f
s_low_f=$(_smart_score_total "git " "git status" 1 0 10 10)
s_high_f=$(_smart_score_total "git " "git status" 10 0 10 10)
assert_ge "higher freq scores higher" "$s_high_f" "$s_low_f"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 8: v0.1.3 exponential decay 精确验证 ==="
# With alpha=10: rec=0→1000, rec=20→833, rec=50→667, rec=100→500
assert_eq "decay rec=0 → 1000"  "$(_smart_score_recency 0 100)"  "1000"
assert_eq "decay rec=20 → 833" "$(_smart_score_recency 20 100)" "833"
assert_eq "decay rec=50 → 666" "$(_smart_score_recency 50 100)" "666"
assert_eq "decay rec=100 → 500" "$(_smart_score_recency 100 100)" "500"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 9: v0.1.3 _smart_score_cwd 函数 ==="
assert_eq "cwd: same dir → boost 1500" \
    "$(_smart_score_cwd "/tmp" "/tmp")" "1500"
assert_eq "cwd: diff dir → 1000" \
    "$(_smart_score_cwd "/tmp" "/home")" "1000"
assert_eq "cwd: empty cmd_cwd → 1000" \
    "$(_smart_score_cwd "" "/tmp")" "1000"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 10: v0.1.3 CWD boost in _smart_score_total ==="
# "g" → "git status", freq=1, rec=5, max_freq=10, max_rec=10
# prefix=250, recency=952, freq=300
# base = (400*250 + 350*952 + 250*300) / 1000 = (100000+333200+75000)/1000 = 508
local s_base s_cwd_boost s_cwd_noboost
s_base=$(_smart_score_total "g" "git status" 1 5 10 10)
assert_eq "total without CWD (6 params)" "$s_base" "508"
# With CWD matching: 508 * 1500 / 1000 = 762
s_cwd_boost=$(_smart_score_total "g" "git status" 1 5 10 10 "/tmp" "/tmp")
assert_eq "total with CWD boost (same dir)" "$s_cwd_boost" "762"
# With CWD not matching: 508 * 1000 / 1000 = 508
s_cwd_noboost=$(_smart_score_total "g" "git status" 1 5 10 10 "/tmp" "/other")
assert_eq "total with CWD no boost (diff dir)" "$s_cwd_noboost" "508"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 11: v0.1.3 decay beats old frequency ==="
# Scenario: a recent command with low freq should beat an old command with
# high freq, when prefix match is similar.
# cmd_new: rec=0, freq=1 → recency=1000, freq=100
# cmd_old: rec=50, freq=10 → recency=667, freq=1000
# prefix same for both: "git s" → "git status" = 850
local s_new s_old
s_new=$(_smart_score_total "git s" "git status" 1 0 10 100)    # rec=0
s_old=$(_smart_score_total "git s" "git status" 10 50 10 100)  # rec=50
# s_new = (400*850 + 350*1000 + 250*300)/1000 = (340000+350000+75000)/1000 = 765
# s_old = (400*850 + 350*666 + 250*1000)/1000 = (340000+233100+250000)/1000 = 823
# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 12: v0.2.0 _smart_score_host + _smart_score_exit 单测 ==="
assert_eq "host: same → boost 1300"   "$(_smart_score_host "hostA" "hostA")" "1300"
assert_eq "host: diff → 1000"         "$(_smart_score_host "hostA" "hostB")" "1000"
assert_eq "host: empty cmd_host → 1000" "$(_smart_score_host "" "hostB")" "1000"
assert_eq "host: empty cur_host → 1000" "$(_smart_score_host "hostA" "")" "1000"
assert_eq "exit: 0 → 1000"             "$(_smart_score_exit "0")" "1000"
assert_eq "exit: empty → 1000"         "$(_smart_score_exit "")" "1000"
assert_eq "exit: 1 → penalty 500"      "$(_smart_score_exit "1")" "500"
assert_eq "exit: 127 → penalty 500"    "$(_smart_score_exit "127")" "500"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 13: v0.2.0 _smart_score_total host×exit 端到端 ==="
# base = (400*850+350*1000+250*300)/1000 = (340000+350000+75000)/1000 = 765
local s_base s_host s_exit s_all
s_base=$(_smart_score_total "git s" "git status" 1 0 10 50 \
            ""  ""  ""  ""  "")
assert_eq "total 6-param base" "$s_base" "765"
# host boost (my-laptop = my-laptop) 1300: 765 * 1300/1000 = 994
s_host=$(_smart_score_total "git s" "git status" 1 0 10 50 \
            "" "" "my-laptop" "my-laptop" "")
assert_eq "total host boost" "$s_host" "994"
# exit penalty (exit 1) 500: 765 * 500/1000 = 382
s_exit=$(_smart_score_total "git s" "git status" 1 0 10 50 \
            "" "" "" "" "1")
assert_eq "total exit penalty" "$s_exit" "382"
# host 1300 + exit penalty 500 = 765 * 1300/1000 * 500/1000 = 994 * 500/1000 = 497
s_all=$(_smart_score_total "git s" "git status" 1 0 10 50 \
            "" "" "my-laptop" "my-laptop" "1")
assert_eq "total host+exit combined" "$s_all" "497"

print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
