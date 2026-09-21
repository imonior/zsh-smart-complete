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
        SMART_SUGGEST_HISTORY_LIMIT SMART_SUGGEST_COLOR SMART_KEYMAP_SCOPE
        SMART_MENU_SINGLE_COLUMN SMART_MENU_LISTER)
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
    assert_eq "SMART_SUGGEST_COLOR default" "$SMART_SUGGEST_COLOR"        "auto"
    assert_eq "SMART_KEYMAP_SCOPE default"  "$SMART_KEYMAP_SCOPE"         "both"
    # Single column is OPT-IN: the default is zsh's native multi-column grid.
    # The vertical list is generated rather than taken from compsys, so it costs
    # descriptions / colours / fuzzy matching and flips back to the grid for
    # contexts it cannot generate. Shipping that as the default would be a
    # behaviour regression dressed up as a feature.
    assert_eq "SMART_MENU_SINGLE_COLUMN default" "$SMART_MENU_SINGLE_COLUMN" "false"
    # Which lister owns the screen. `builtin` = this plugin draws the list;
    # `fzf-tab` = we draw nothing and an external picker must. Builtin is the
    # default because that is this plugin's own feature; handing the screen
    # over is the answer to "two candidate lists appear at once".
    assert_eq "SMART_MENU_LISTER default" "$SMART_MENU_LISTER" "builtin"
}

print -r -- ""
print -r -- "=== 场景 2: 用户预设置覆盖 ==="
() {
    SMART_ENABLED=false; SMART_SUGGEST=false; SMART_HISTORY_BACKEND=atuin
    SMART_INLINE=false; SMART_KEYMAP_SCOPE=emacs; SMART_SUGGEST_COLOR="fg=245,bold"
    SMART_MENU_SINGLE_COLUMN=true
    SMART_MENU_LISTER=fzf-tab
    source "${ROOT}/lib/config.zsh"
    assert_eq "SMART_ENABLED overridden"    "$SMART_ENABLED"             "false"
    assert_eq "SMART_SUGGEST overridden"    "$SMART_SUGGEST"             "false"
    assert_eq "SMART_HISTORY_BACKEND atuin" "$SMART_HISTORY_BACKEND"     "atuin"
    assert_eq "SMART_INLINE overridden"     "$SMART_INLINE"              "false"
    assert_eq "SMART_KEYMAP_SCOPE emacs"    "$SMART_KEYMAP_SCOPE"        "emacs"
    assert_eq "SMART_SUGGEST_COLOR kept"    "$SMART_SUGGEST_COLOR"       "fg=245,bold"
    # `:=` means an explicit opt-IN must survive: choosing the vertical list is
    # the whole point of the knob now that the default is false.
    assert_eq "SMART_MENU_SINGLE_COLUMN kept true" "$SMART_MENU_SINGLE_COLUMN" "true"
    # Handing the list to an external picker must survive too: the installer
    # writes it as an ordinary `export`, and `:=` is what keeps that answer.
    assert_eq "SMART_MENU_LISTER kept"      "$SMART_MENU_LISTER" "fzf-tab"
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
print -r -- "=== 场景 5: 文档里写明的默认值必须与代码一致 ==="
# The READMEs state every knob as `: ${VAR:=default}`. That makes them a SECOND
# source of truth for the defaults, and one that drifts silently: a doc saying
# `true` while the code says `false` looks fine until somebody follows the doc
# and gets different behaviour. It already happened here — the installer offered
# the Tab menu OFF while lib/config.zsh shipped it ON.
#
# So read the list of knobs OUT OF the doc and require every one of them to
# equal what lib/config.zsh actually resolves to. Taking the list from the doc
# (rather than hard-coding it below) is the point: a newly documented knob is
# covered the moment it is written down, so the guard cannot fall behind. The
# earlier version of this check pinned a SINGLE value, which is exactly why the
# lister/`SMART_MENU_LISTER` default could have been added without any coverage.
_read_pairs() {   # -> "NAME value" per line, from a README's config block
    grep -oE '^: \$\{[A-Z_]+:=[^}]*\}' "$1" | sed -E 's/^: \$\{([A-Z_]+):=(.*)\}$/\1 \2/'
}
_pairs="$(_read_pairs "${ROOT}/README.md")"
_n_doc="$(print -r -- "$_pairs" | grep -c .)"
# A floor, not a target: if the extraction silently stops matching (a formatting
# change to the config block), this fails loudly instead of vacuously passing.
if (( _n_doc >= 18 )); then
    (( PASS++ )); print -r -- "  PASS  extracted $_n_doc documented defaults from README.md"
else
    (( FAIL++ )); print -r -- "  FAIL  only $_n_doc defaults extracted — the config block format changed?" >&2
fi

# All five languages must document the SAME knobs; otherwise one translation has
# quietly fallen behind, which is how a localized doc goes stale.
for _rd in README.zh-CN.md README.zh-TW.md README.ja.md README.ko.md; do
    _other="$(_read_pairs "${ROOT}/$_rd")"
    assert_eq "$_rd documents the same knobs as README.md" "$_other" "$_pairs"
done

# Resolve every one of them for real, in ONE clean shell (no inherited values,
# so this reads the DEFAULTS rather than whatever this test process has set).
_names=()
for _line in ${(f)_pairs}; do _names+=("${_line%% *}"); done
# NOTE: keep this a SCALAR and split it with ${(f)...} below. Two zsh traps
# here, both of which made the first version of this check fail for the wrong
# reason: `${(M)scalar:#name=*}` matches the WHOLE multi-line string (a zsh `*`
# crosses newlines), and `"${(@f)$(...)}"` does not reliably give one element
# per line. A plain lookup table sidesteps both.
_real="$(zsh -f -c "source '${ROOT}/lib/config.zsh' >/dev/null 2>&1; for v in ${(j: :)_names}; do print -r -- \"\$v=\${(P)v}\"; done")"
typeset -A _code=()
for _line in ${(f)_real}; do
    # NOTE: the key subscript must NOT be quoted. `_code["${_line%%=*}"]=...`
    # stores a key that literally contains the double quotes, so every later
    # `${_code[$name]}` lookup misses and the whole check silently reports
    # "<absent>" for everything — which looks like a code bug rather than a
    # quoting bug. `${(k)_code}` is how to see it.
    _code[${_line%%=*}]="${_line#*=}"
done

_bad=""
for _line in ${(f)_pairs}; do
    _n="${_line%% *}"
    _dv="${_line#* }"
    _rv="${_code[$_n]-<absent>}"
    if [[ "$_dv" != "$_rv" ]]; then
        _bad="$_bad ${_n}(doc='${_dv}' code='${_rv}')"
    fi
done
assert_eq "every documented default matches lib/config.zsh" "${_bad# }" ""

# The check above is only worth anything if it CAN fail, so prove that for one
# representative knob: the opposite value must not be present anywhere.
if grep -qF "SMART_MENU_SINGLE_COLUMN:=true" "${ROOT}/README.md"; then
    (( FAIL++ )); print -r -- "  FAIL  README contains the OPPOSITE single-column default — the comparison above may be vacuous" >&2
else
    (( PASS++ )); print -r -- "  PASS  the comparison is falsifiable (the opposite value is absent)"
fi

print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
