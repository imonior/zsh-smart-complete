#!/usr/bin/env zsh
# tests/test-native.zsh
#
# Unit tests for the native completion bridge (lib/engine/native.zsh).
#
# What this module promises is narrow but load-bearing: whatever Tab did before
# this plugin was loaded, Tab still does — and when the user never ran compinit,
# Tab is a tab rather than a wall of "_main_complete: command not found". Those
# two properties live in the compsys probe, the binding capture, and the
# dispatch fallback chain, which is what this file exercises.
#
# How it runs outside ZLE:
#   * $bindkey and its keymaps work in a plain shell, so the capture/restore
#     tests use the real thing.
#   * $widgets is populated too, so the "does that widget still exist" check is
#     tested against the real table using real widget names.
#   * `zle` itself is the one thing that cannot run without a terminal, so it is
#     replaced by a mock that records which widget was dispatched. The mock is
#     defined AFTER native.zsh is sourced: a function named `zle` shadows the
#     builtin, and native.zsh registers its widgets with `zle -N` at load time.

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
    "$@"; local rc=$?
    if (( rc == want )); then
        (( PASS++ )); print -r -- "  PASS  $name"
    else
        (( FAIL++ )); print -r -- "  FAIL  $name  rc=$rc want=$want" >&2
    fi
}

source "${ROOT}/lib/config.zsh"
source "${ROOT}/lib/state.zsh"
source "${ROOT}/lib/display/display.zsh"
source "${ROOT}/lib/engine/native.zsh"

# --- the one mock: record what got dispatched to ZLE -----------------------
ZLE_CALLED="<nothing>"
zle() {
    ZLE_CALLED="$1"
    return 0
}

# --- compsys presence, toggled by hand ------------------------------------
_with_compsys() {
    compdef() { return 0 }
    typeset -gA _comps=()
}
_without_compsys() {
    unfunction compdef 2>/dev/null
    unset _comps 2>/dev/null
}

print -r -- "=== 场景 1: _smart_native_have_compinit ==="
_without_compsys
assert_rc "no compdef -> no compsys" 1 _smart_native_have_compinit
compdef() { return 0 }
assert_rc "compdef but no _comps -> no compsys" 1 _smart_native_have_compinit
unset _comps 2>/dev/null
typeset -g _comps="not an association"
assert_rc "_comps that is not an association -> no compsys" 1 _smart_native_have_compinit
unset _comps
_with_compsys
assert_rc "compdef + _comps -> compsys" 0 _smart_native_have_compinit
_without_compsys

print -r -- ""
print -r -- "=== 场景 2: _smart_current_binding ==="
# bindkey's output is "<key> <widget>"; only the last field may be read as the
# widget, because for a raw-byte key sequence the echoed line does not contain
# those bytes. The mock controls the exact text the real builtin would not let
# us write in a portable way.
_binding_of() { print -r -- "$(_smart_current_binding emacs $'\t')" }
bindkey() {
    case "$BINDKEY_MOCK" in
        bound)     print -r -- '"^I" expand-or-complete' ;;
        rawkey)    print -r -- '"^D^T" complete-word' ;;
        undefined) print -r -- '"^I" undefined-key' ;;
        own)       print -r -- '"^I" _smart_native_complete' ;;
        cmd)       print -r -- '"^I" smart-accept-suggestion' ;;
        error)     return 1 ;;
    esac
}
BINDKEY_MOCK=bound;     assert_eq "widget name"              "$(_binding_of)" "expand-or-complete"
BINDKEY_MOCK=rawkey;   assert_eq "raw-byte key text ignored" "$(_binding_of)" "complete-word"
BINDKEY_MOCK=undefined; assert_eq "undefined-key reads as unbound" "$(_binding_of)" ""
BINDKEY_MOCK=own;      assert_eq "our own widget reads as unbound" "$(_binding_of)" ""
BINDKEY_MOCK=cmd;      assert_eq "our smart-* command reads as unbound" "$(_binding_of)" ""
BINDKEY_MOCK=error;    assert_eq "failing lookup reads as unbound" "$(_binding_of)" ""
unfunction bindkey
# And the same helper against the real builtin.
bindkey -M emacs -- $'\t' complete-word
assert_eq "real bindkey: widget round-trip" "$(_smart_current_binding emacs $'\t')" "complete-word"

print -r -- ""
print -r -- "=== 场景 3: save + restore the user's Tab ==="
bindkey -M viins -- $'\t' expand-or-complete
bindkey -M vicmd -- $'\t' complete-word
assert_rc "save" 0 _smart_native_save_original_bindings
assert_eq "saved emacs"  "$_SMART_NATIVE_ORIG_TAB_EMACS" "complete-word"
assert_eq "saved viins"  "$_SMART_NATIVE_ORIG_TAB_VIINS" "expand-or-complete"
assert_eq "saved vicmd"  "$_SMART_NATIVE_ORIG_TAB_VICMD" "complete-word"
# The plugin takes over, then gives up exactly what it found.
bindkey -M emacs -- $'\t' _smart_native_complete
bindkey -M viins -- $'\t' _smart_native_complete
bindkey -M vicmd -- $'\t' _smart_native_complete
assert_eq "our widget is in place" "$(_smart_current_binding emacs $'\t')" ""
assert_rc "restore" 0 _smart_native_restore_original_bindings
assert_eq "emacs Tab back to the user's widget" \
    "$(_smart_current_binding emacs $'\t')"  "complete-word"
assert_eq "viins Tab back"                  "$(_smart_current_binding viins $'\t')" "expand-or-complete"
assert_eq "vicmd Tab back"                  "$(_smart_current_binding vicmd $'\t')" "complete-word"
# A user whose Tab was unbound must get an unbound Tab back, not a stale widget.
_SMART_NATIVE_ORIG_TAB_EMACS=""
bindkey -M emacs -- $'\t' _smart_native_complete
assert_rc "restore with nothing saved" 0 _smart_native_restore_original_bindings
assert_eq "unbound stays unbound" "$(_smart_current_binding emacs $'\t')" ""

print -r -- ""
print -r -- "=== 场景 4: _smart_native_call_original ==="
_without_compsys
# The captured widget is still a real one, so it is used verbatim.
_SMART_NATIVE_ORIG_TAB_EMACS="complete-word"
ZLE_CALLED="<nothing>"
assert_rc "dispatch to the captured widget" 0 _smart_native_call_original emacs
assert_eq "zle got complete-word" "$ZLE_CALLED" "complete-word"
# Plugin uninstalled under our feet: the widget name is gone.
_SMART_NATIVE_ORIG_TAB_EMACS="widget-from-an-unloaded-plugin"
_smart_native_call_original emacs
assert_eq "vanished widget, no compsys -> self-insert" "$ZLE_CALLED" "self-insert"
_with_compsys
_smart_native_call_original emacs
assert_eq "vanished widget, compsys alive -> expand-or-complete" "$ZLE_CALLED" "expand-or-complete"
_without_compsys
_SMART_NATIVE_ORIG_TAB_EMACS=""
_smart_native_call_original emacs
assert_eq "never bound, no compsys -> self-insert" "$ZLE_CALLED" "self-insert"
_with_compsys
_smart_native_call_original emacs
assert_eq "never bound, compsys alive -> expand-or-complete" "$ZLE_CALLED" "expand-or-complete"
# Keymap selection: the hint is what a script can supply, since $KEYMAP only
# exists while ZLE is running a widget. Every name below is a real widget,
# because a captured name that no longer exists is deliberately ignored (tested
# above) — and with compsys on, a wrong branch would answer "expand-or-complete"
# instead, which is none of these three.
_with_compsys
_SMART_NATIVE_ORIG_TAB_EMACS="self-insert"
_SMART_NATIVE_ORIG_TAB_VIINS="complete-word"
_SMART_NATIVE_ORIG_TAB_VICMD="menu-complete"
ZLE_CALLED="<nothing>"
assert_rc "viins hint" 0 _smart_native_call_original viins
assert_eq "viins uses the viins binding" "$ZLE_CALLED" "complete-word"
_smart_native_call_original vicmd
assert_eq "vicmd uses the vicmd binding" "$ZLE_CALLED" "menu-complete"
_smart_native_call_original emacs
assert_eq "emacs hint uses the emacs binding" "$ZLE_CALLED" "self-insert"
_without_compsys

print -r -- ""
print -r -- "=== 场景 5: the Tab widget's two-state model ==="
_SMART_NATIVE_ORIG_TAB_EMACS="expand-or-complete"
_smart_native_reset_completion
assert_eq "starts inactive" "$_SMART_COMPLETION_ACTIVE" "0"
# Tab clears the ghost first: completion and suggestion are separate channels.
BUFFER="git s"; POSTDISPLAY="tatus"
region_highlight=("5 10 fg=8  memo=${_SMART_RH_MARKER}")
assert_rc "first Tab" 0 _smart_native_complete
assert_eq "first Tab clears the inline ghost" "$POSTDISPLAY" ""
assert_eq "first Tab dispatches the user's widget" "$ZLE_CALLED" "expand-or-complete"
assert_eq "first Tab arms the completion state"    "$_SMART_COMPLETION_ACTIVE" "1"
ZLE_CALLED="<nothing>"
assert_rc "second Tab" 0 _smart_native_complete
assert_eq "second Tab cycles the menu" "$ZLE_CALLED" "menu-complete"
assert_eq "state stays armed"          "$_SMART_COMPLETION_ACTIVE" "1"
assert_rc "reset_completion" 0 _smart_native_reset_completion
assert_eq "reset disarms"      "$_SMART_COMPLETION_ACTIVE" "0"
# SMART_COMPLETE=off hands Tab straight back, and must not look like a
# half-open menu to the next keystroke.
ZLE_CALLED="<nothing>"
SMART_COMPLETE="off"
_smart_native_complete
assert_eq "off: original widget runs" "$ZLE_CALLED" "expand-or-complete"
assert_eq "off: completion state untouched" "$_SMART_COMPLETION_ACTIVE" "0"
SMART_COMPLETE="true"

print -r -- ""
print -r -- "=== 场景 6: shift+Tab ==="
ZLE_CALLED="<nothing>"
assert_rc "reverse Tab" 0 _smart_native_reverse_complete
assert_eq "cycles backwards" "$ZLE_CALLED" "reverse-menu-complete"

print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
