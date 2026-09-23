#!/usr/bin/env zsh
# tests/test-settings.zsh
#
# Unit tests for bin/zsc-settings — the local settings manager the installer
# drops next to the plugin. Drives the script against a throwaway config dir
# and asserts on its read/write/validate/reset behaviour. The wizard is not
# exercised here (it requires a TTY); every non-interactive subcommand is.
emulate -L zsh
setopt extended_glob no_warn_create_global

ROOT="${0:a:h:h}"
WIZ="$ROOT/bin/zsc-settings"
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

# Drive the wizard in a fully isolated location.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zsc_set.XXXXXX")"
export XDG_CONFIG_HOME="$TMP"
export SMART_USER_CONFIG="$TMP/settings.zsh"
run() { zsh "$WIZ" "$@"; }

print -r -- "=== 场景 1: init 创建带注释默认值的文件 ==="
run init >/dev/null 2>&1
assert_eq "init creates the file" "$([[ -f "$SMART_USER_CONFIG" ]] && print yes || print no)" "yes"
assert_eq "path prints the file path" "$(run path)" "$SMART_USER_CONFIG"
# A freshly-init'd file must not contain a single uncommented override line.
_uncommented="$(grep -cE '^[[:space:]]*[A-Z][A-Z0-9_]*=' "$SMART_USER_CONFIG" 2>/dev/null)"
assert_eq "init writes only comments (no overrides)" "$_uncommented" "0"

print -r -- "=== 场景 2: get 返回生效值（默认值） ==="
assert_eq "SMART_MENU default"        "$(run get SMART_MENU)"        "true"
assert_eq "SMART_SUGGEST_COLOR def"  "$(run get SMART_SUGGEST_COLOR)" "auto"
assert_eq "SMART_HISTORY_BACKEND def" "$(run get SMART_HISTORY_BACKEND)" "zsh"

print -r -- "=== 场景 3: set 写入并通过类型校验 ==="
run set SMART_MENU false >/dev/null 2>&1
assert_eq "set bool takes effect" "$(run get SMART_MENU)" "false"
run set SMART_HISTORY_BACKEND atuin >/dev/null 2>&1
assert_eq "set enum takes effect" "$(run get SMART_HISTORY_BACKEND)" "atuin"
run set SMART_SUGGEST_MAX 5 >/dev/null 2>&1
assert_eq "set int takes effect" "$(run get SMART_SUGGEST_MAX)" "5"
run set SMART_SUGGEST_STRATEGY completion >/dev/null 2>&1
assert_eq "set multi-value enum" "$(run get SMART_SUGGEST_STRATEGY)" "completion"
# the override is written verbatim as KEY='VALUE'
assert_eq "override line written" "$(grep -cE "^SMART_MENU='false'" "$SMART_USER_CONFIG")" "1"

print -r -- "=== 场景 4: set 拒绝非法类型 ==="
run set SMART_MENU notabool >/dev/null 2>&1; rc=$?
assert_eq "bad bool is rejected (nonzero exit)" "$rc" "1"
assert_eq "bad bool did not change value" "$(run get SMART_MENU)" "false"
run set SMART_SUGGEST_MAX abc >/dev/null 2>&1; rc=$?
assert_eq "bad int is rejected" "$rc" "1"
run set SMART_HISTORY_BACKEND bogus >/dev/null 2>&1; rc=$?
assert_eq "bad enum is rejected" "$rc" "1"
assert_eq "bad enum did not change value" "$(run get SMART_HISTORY_BACKEND)" "atuin"

print -r -- "=== 场景 5: reset 单个覆盖回到默认 ==="
run reset SMART_MENU >/dev/null 2>&1
assert_eq "reset one -> default" "$(run get SMART_MENU)" "true"
assert_eq "reset removed the override line" "$(grep -cE "^SMART_MENU=" "$SMART_USER_CONFIG")" "0"

print -r -- "=== 场景 6: reset 全部覆盖 ==="
_uncommented_before="$(grep -cE '^[[:space:]]*[A-Z][A-Z0-9_]*=' "$SMART_USER_CONFIG" 2>/dev/null)"
assert_eq "overrides exist before full reset" "$_uncommented_before" "3"
run reset >/dev/null 2>&1
_uncommented_after="$(grep -cE '^[[:space:]]*[A-Z][A-Z0-9_]*=' "$SMART_USER_CONFIG" 2>/dev/null)"
assert_eq "full reset leaves no overrides" "$_uncommented_after" "0"
assert_eq "SMART_SUGGEST_MAX back to default" "$(run get SMART_SUGGEST_MAX)" "1"

print -r -- "=== 场景 7: list 列出全部设置 ==="
run list 2>&1 | grep -q 'SMART_SUGGEST_COLOR' && _has=1 || _has=0
assert_eq "list mentions a known key" "$_has" "1"

print -r -- "=== 场景 8: edit 在文件缺失时先 init ==="
rm -f -- "$SMART_USER_CONFIG"
run edit >/dev/null 2>&1
assert_eq "edit creates file when missing" "$([[ -f "$SMART_USER_CONFIG" ]] && print yes || print no)" "yes"

rm -rf -- "$TMP"
print -r -- "=== TOTAL: $PASS passed, $((FAIL)) failed ==="
(( FAIL == 0 ))
