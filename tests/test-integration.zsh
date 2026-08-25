#!/usr/bin/env zsh
# tests/test-integration.zsh -- full plugin smoke test
#  Verifies: silent source, double-source guard, all public symbols present,
#  smart-status / disable / enable / reindex CLI work, backend tolerance.

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
assert_contains() {
    local name="$1" hay="$2" needle="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        (( PASS++ )); print -r -- "  PASS  $name"
    else
        (( FAIL++ )); print -r -- "  FAIL  $name  missing [$needle] in [$hay]" >&2
    fi
}
assert_fn_exists() {
    local fn="$1"
    if (( ${+functions[$fn]} )); then
        (( PASS++ )); print -r -- "  PASS  function $fn exists"
    else
        (( FAIL++ )); print -r -- "  FAIL  function $fn missing" >&2
    fi
}

# ---------------------------------------------------------------------------
# Scenario 1: fresh plugin source in a CLEAN environment must be silent,
#   define every public function, and set SMART_SOURCED=1.
# ---------------------------------------------------------------------------
print -r -- "=== 场景 1: 干净加载插件 (source = 0 stderr, 0 stdout) ==="
(
    # Subshell = separate scope. Unset anything that could leak from
    # the test harness environment (e.g. zinit, this test script itself).
    unset _SMART_STATE _SMART_STATE_A _SMART_STATE_L SMART_ROOT SMART_SOURCED
    local v
    for v in SMART_ENABLED SMART_SUGGEST SMART_COMPLETE SMART_HISTORY_BACKEND \
             SMART_INLINE SMART_SUGGEST_MAX SMART_HISTORY_REBUILD_EVERY \
             SMART_SUGGEST_HISTORY_LIMIT SMART_SUGGEST_COLOR SMART_KEYMAP_SCOPE
    do unset "$v"; done
    local f
    for f in smart-status smart-enable smart-disable smart-reindex smart-toggle \
             _smart_state_get _smart_state_set _smart_state_reset \
             _smart_history_rebuild _smart_history_iter_prefix \
             _smart_suggest_compute _smart_suggest_get_text \
             _smart_native_have_compinit _smart_native_complete \
             _smart_native_reverse_complete _smart_native_reset_completion \
             _smart_display_show _smart_display_clear _smart_display_update \
             _smart_event_bind _smart_event_unbind _smart_widget_self_insert
    do unfunction "$f" 2>/dev/null; done

    SE=$(mktemp)
    SO=$(mktemp)
    source "${ROOT}/zsh-smart-complete.plugin.zsh" >"$SO" 2>"$SE"
    local rc=$?
    local stderr_body stdout_body
    stderr_body="$(cat "$SE"; )"
    stdout_body="$(cat "$SO"; )"
    rm -f "$SE" "$SO"

    print -r -- "__START__"
    print -r -- "rc:${rc}"
    print -r -- "stderr_len:${#stderr_body}"
    print -r -- "stdout_len:${#stdout_body}"
    print -r -- "SMART_SOURCED:${SMART_SOURCED}"
    print -r -- "has_smart_status:${${(k)functions[(I)smart-status]}:+1}${${(k)functions[(I)smart-status]:-}}"
    # Recompute without broken parameter expansion fallback:
    if (( ${+functions[smart-status]} )); then print -r -- "fn_status:1"
    else print -r -- "fn_status:0"; fi
    local required_count=0
    local required_total=0
    for fn in smart-status smart-enable smart-disable smart-reindex smart-toggle \
              _smart_state_get _smart_state_set _smart_state_reset \
              _smart_history_rebuild _smart_history_iter_prefix \
              _smart_suggest_compute _smart_suggest_get_text \
              _smart_native_have_compinit _smart_native_complete \
              _smart_native_reverse_complete _smart_native_reset_completion \
              _smart_display_show _smart_display_clear _smart_display_update \
              _smart_event_bind _smart_event_unbind; do
        (( required_total++ ))
        (( ${+functions[$fn]} )) && (( required_count++ ))
    done
    print -r -- "required:${required_count}/${required_total}"
    # Also check double-source is a no-op.
    SE2=$(mktemp); SO2=$(mktemp)
    source "${ROOT}/zsh-smart-complete.plugin.zsh" >"$SO2" 2>"$SE2"
    local rc2=$?
    local e2=$(cat "$SE2"); local o2=$(cat "$SO2")
    rm -f "$SE2" "$SO2"
    print -r -- "double_rc:${rc2}"
    print -r -- "double_stderr_len:${#e2}"
    print -r -- "double_stdout_len:${#o2}"
    print -r -- "__END__"
) | {
    local buf=""
    local line
    while IFS= read -r line; do buf+="$line"$'\n'; done
    # Extract lines between markers.
    local inner="${buf#*$'__START__\n'}"
    inner="${inner%$'\n'__END__*}"
    local -A kv
    local kvline
    for kvline in "${(f)inner}"; do
        case "$kvline" in
            rc:*|stderr_len:*|stdout_len:*|SMART_SOURCED:*|fn_status:*|required:*|double_rc:*|double_stderr_len:*|double_stdout_len:*)
                local k="${kvline%%:*}" v="${kvline#*:}"
                kv[$k]="$v"
                ;;
        esac
    done
    assert_eq "source rc=0"                    "${kv[rc]}"                "0"
    assert_eq "stderr empty"                   "${kv[stderr_len]}"        "0"
    assert_eq "stdout empty"                   "${kv[stdout_len]}"        "0"
    assert_eq "SMART_SOURCED=1"                "${kv[SMART_SOURCED]}"     "1"
    assert_eq "fn smart-status defined"        "${kv[fn_status]}"         "1"
    assert_eq "all 21 required fns present"    "${kv[required]}"          "21/21"
    assert_eq "double-source rc=0"             "${kv[double_rc]}"         "0"
    assert_eq "double-source stderr empty"     "${kv[double_stderr_len]}" "0"
    assert_eq "double-source stdout empty"     "${kv[double_stdout_len]}" "0"
}

# ---------------------------------------------------------------------------
# Scenario 2: source into this shell for the rest of the checks.
# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 2: 当前 shell 加载全部 public functions ==="
# Force unload before.
() {
    local v f
    for v in SMART_ENABLED SMART_SUGGEST SMART_COMPLETE SMART_HISTORY_BACKEND \
             SMART_INLINE SMART_SUGGEST_MAX SMART_HISTORY_REBUILD_EVERY \
             SMART_SUGGEST_HISTORY_LIMIT SMART_SUGGEST_COLOR SMART_KEYMAP_SCOPE \
             SMART_SOURCED SMART_ROOT
    do unset "$v" 2>/dev/null; done
    unset _SMART_STATE _SMART_STATE_A _SMART_STATE_L 2>/dev/null
    for f in smart-status smart-enable smart-disable smart-reindex smart-toggle \
             _smart_state_get _smart_state_set _smart_state_reset \
             _smart_state_a_get _smart_state_a_set _smart_state_a_unset_sub \
             _smart_state_l_get _smart_state_l_set \
             _smart_history_rebuild _smart_history_iter_prefix \
             _smart_suggest_compute _smart_suggest_get_text \
             _smart_native_have_compinit _smart_native_complete \
             _smart_native_reverse_complete _smart_native_reset_completion \
             _smart_display_show _smart_display_clear _smart_display_update \
             _smart_event_bind _smart_event_unbind; do
        unfunction "$f" 2>/dev/null
    done
}
source "${ROOT}/zsh-smart-complete.plugin.zsh" >/dev/null 2>&1
for f in smart-status smart-enable smart-disable smart-reindex smart-toggle \
         _smart_state_get _smart_state_set _smart_state_reset \
         _smart_state_a_get _smart_state_a_set _smart_state_a_unset_sub \
         _smart_state_l_get _smart_state_l_set \
         _smart_history_rebuild _smart_history_iter_prefix \
         _smart_suggest_compute _smart_suggest_get_text \
         _smart_native_have_compinit _smart_native_complete \
         _smart_native_reverse_complete _smart_native_reset_completion \
         _smart_display_show _smart_display_clear _smart_display_update \
         _smart_event_bind _smart_event_unbind; do
    assert_fn_exists "$f"
done
assert_eq "SMART_SOURCED=1 after source" "$SMART_SOURCED" "1"

# ---------------------------------------------------------------------------
# Scenario 3: CLI commands.
# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 3: smart-status / disable / enable / toggle / reindex ==="
status_out=$(smart-status 2>&1)
assert_contains "status has version"  "$status_out" "zsh-smart-complete"
assert_contains "status has enabled"  "$status_out" "enabled:"
assert_contains "status has suggest"  "$status_out" "suggest:"
assert_contains "status has complete" "$status_out" "complete:"
assert_contains "status has backend"  "$status_out" "backend:"

smart-disable 2>/dev/null
assert_eq "smart-disable → enabled=0" "$(_smart_state_get enabled)" "0"
smart-enable 2>/dev/null
assert_eq "smart-enable  → enabled=1" "$(_smart_state_get enabled)" "1"
assert_eq "smart-enable rc=0" "$?" "0"

# Run rebuild via smart-reindex CLI (should succeed with either zsh/atuin backend)
smart-reindex >/dev/null 2>&1
assert_eq "smart-reindex rc=0" "$?" "0"
local c=$(_smart_state_get history.count)
if [[ "$c" =~ '^[0-9]+$' ]]; then
    (( PASS++ )); print -r -- "  PASS  history.count numeric: $c"
else
    (( FAIL++ )); print -r -- "  FAIL  history.count not numeric: [$c]" >&2
fi

# ---------------------------------------------------------------------------
# Scenario 4: suggestion e2e with a hand-injected index.
# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 4: suggestion 端到端（注入已知数据 → "git s" → "git status"） ==="
() {
    _smart_state_a_unset_sub "history.frequency"
    _smart_state_a_unset_sub "history.recency"
    local -a order=("git status" "git checkout main" "ls -la" "git pull" "git add .")
    local -A freq=(["git status"]=12 ["git checkout main"]=4 ["ls -la"]=25 ["git pull"]=3 ["git add ."]=5)
    local rec=0 mx=0 c
    for c in "${order[@]}"; do
        _smart_state_a_set history.recency "$c" "$rec"; (( rec++ ))
        (( freq[$c] > mx )) && mx=${freq[$c]}
        _smart_state_a_set history.frequency "$c" "${freq[$c]}"
    done
    _smart_state_l_set history.cmds "${order[@]}"
    _smart_state_set history.count "${#order}"
    _smart_state_set history.max_freq "$mx"
    _smart_state_set history.max_recency "$(( rec - 1 ))"
}
_smart_suggest_compute "git s"
local t=$(_smart_state_get suggestion.text)
local src=$(_smart_state_get suggestion.source)
assert_eq "git s → git status"     "$t"   "git status"
assert_eq "source=history"          "$src" "history"

_smart_suggest_compute "git check"
t=$(_smart_state_get suggestion.text)
assert_eq "git check → git checkout main" "$t" "git checkout main"

_smart_suggest_compute "no_such_prefix_xyz"
t=$(_smart_state_get suggestion.text)
assert_eq "empty input/suggestion cleared" "$t" ""

# ---------------------------------------------------------------------------
# Scenario 5: SMART_HISTORY_BACKEND permutations don't crash rebuild.
# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 5: backend zsh/atuin 切换时 history rebuild 不崩溃 ==="
local be old_backend="$SMART_HISTORY_BACKEND"
for be in zsh atuin; do
    SMART_HISTORY_BACKEND="$be"
    _smart_history_rebuild >/dev/null 2>&1
    assert_eq "backend=$be rebuild rc=0" "$?" "0"
done
SMART_HISTORY_BACKEND="$old_backend"

print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
