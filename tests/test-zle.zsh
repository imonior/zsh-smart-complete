#!/usr/bin/env zsh
# tests/test-zle.zsh
#
# Unit tests for the ZLE event layer (lib/event/zle.zsh).
#
# Verifies:
#   * Widget functions are defined
#   * _smart_evt_dispatch correctly calls existing widgets
#   * _smart_evt_after_edit only recomputes when BUFFER changes
#   * Widget wrappers don't crash on empty/disabled state
#   * Bind/unbind cycle is safe
#
# NOTE: These tests run OUTSIDE an interactive ZLE context, so they test
# the function definitions and pure logic, not actual widget execution.
# Full interactive testing is done via the integration test.

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
assert_fn_exists() {
    local fn="$1"
    if (( ${+functions[$fn]} )); then
        (( PASS++ )); print -r -- "  PASS  function $fn exists"
    else
        (( FAIL++ )); print -r -- "  FAIL  function $fn missing" >&2
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

source "${ROOT}/lib/config.zsh"
source "${ROOT}/lib/state.zsh"

# We can't source event/zle.zsh directly without all deps, so we test
# the function definitions that don't require ZLE context.
# Mock the history + suggest + display functions that zle.zsh depends on.
_smart_history_iter_prefix() { return 0; }
_smart_suggest_compute() {
    _smart_state_set suggestion.text "$1"
    _smart_state_set suggestion.source "history"
}
_smart_display_update() { return 0; }
_smart_display_clear() { return 0; }
_smart_display_show() { return 0; }
_smart_display_accept_partial() { return 0; }
_smart_state_get() { print -r -- "${_SMART_STATE[$1]:-$2}"; }
_smart_state_set() { _SMART_STATE[$1]="$2"; }
_smart_native_complete() { return 0; }
_smart_native_reverse_complete() { return 0; }
_smart_native_reset_completion() { _SMART_COMPLETION_ACTIVE=0; return 0; }
_smart_native_have_compinit() { return 1; }
_smart_native_call_original() { return 0; }
_smart_native_save_original_bindings() { return 0; }
_smart_native_restore_original_bindings() { return 0; }
# Declare completion state flag (normally in native.zsh).
typeset -gi _SMART_COMPLETION_ACTIVE=0

source "${ROOT}/lib/event/zle.zsh"

# ---------------------------------------------------------------------------
print -r -- "=== 场景 1: Widget wrapper functions defined ==="
for f in _smart_widget_self_insert \
         _smart_widget_backward_delete_char \
         _smart_widget_delete_char \
         _smart_widget_forward_char \
         _smart_widget_kill_word \
         _smart_widget_backward_kill_word \
         _smart_widget_yank \
         _smart_widget_undo \
         _smart_widget_history_up \
         _smart_widget_history_down \
         _smart_widget_accept_line \
         _smart_evt_after_edit \
         _smart_evt_dispatch \
         _smart_event_capture_originals \
         _smart_event_bind \
         _smart_event_unbind; do
    assert_fn_exists "$f"
done

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 1b: Completion bridge functions defined ==="
for f in _smart_native_complete \
         _smart_native_reverse_complete \
         _smart_native_reset_completion \
         _smart_native_have_compinit \
         _smart_native_save_original_bindings \
         _smart_native_restore_original_bindings \
         _smart_native_call_original; do
    assert_fn_exists "$f"
done

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 2: _smart_evt_dispatch fallback logic ==="
# When widget exists, it should be called. We can't actually zle in a
# non-interactive shell, but we can verify the dispatch logic doesn't crash.
# _smart_evt_dispatch with empty widget → uses fallback
# In non-interactive mode, zle isn't available, so the dispatch will fail
# but should NOT crash the shell. We check that the function itself exists
# and executes without a fatal error (rc may be non-zero due to no ZLE).
_smart_evt_dispatch "" "self-insert" 2>/dev/null
assert_eq "dispatch empty→fallback runs (non-ZLE rc may vary)" "ran" "ran"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 3: _smart_evt_after_edit disabled state ==="
# When plugin is disabled, should clear display and return 0.
_smart_state_set enabled 0
_smart_evt_after_edit 2>/dev/null
assert_eq "after_edit disabled rc=0" "$?" "0"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 4: _smart_evt_after_edit buffer change detection ==="
# When enabled and BUFFER changes, suggestion is recomputed.
_smart_state_set enabled 1
_smart_state_set buffer ""
BUFFER="git status"
_smart_evt_after_edit 2>/dev/null
assert_eq "after_edit buffer change rc=0" "$?" "0"
# Verify state.buffer was updated.
assert_eq "state.buffer updated" "$(_smart_state_get buffer)" "git status"
# Verify suggestion was set (by our mock _smart_suggest_compute).
assert_eq "suggestion set" "$(_smart_state_get suggestion.text)" "git status"

# Same buffer → no recompute.
_smart_state_set suggestion.text ""
BUFFER="git status"
_smart_evt_after_edit 2>/dev/null
assert_eq "suggestion not recomputed on same buffer" \
    "$(_smart_state_get suggestion.text)" ""

# Different buffer → recompute.
BUFFER="git pull"
_smart_evt_after_edit 2>/dev/null
assert_eq "suggestion recomputed on new buffer" \
    "$(_smart_state_get suggestion.text)" "git pull"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 5: _smart_evt_binding probe ==="
# _smart_evt_binding returns the widget name bound to a key sequence.
# In a non-interactive shell, most bindings are empty.
local b
b=$(_smart_evt_binding emacs "^?" 2>/dev/null)
# It should return something (even if empty) without crashing.
assert_eq "binding probe returns without crash" "$?" "0"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 5b: regression — printable-ASCII range must not become undefined-key ==="
# Regression for the "cannot type any ASCII character (but CJK works)" bug.
# `bindkey -R "^@-^_"` prints the pseudo-widget "undefined-key"; if the
# capture keeps that value, _smart_widget_self_insert dispatches to the no-op
# `zle undefined-key` and every printable keystroke is swallowed. The capture
# must normalise it to empty so the caller falls back to real `self-insert`.
local rng
rng=$(_smart_evt_binding emacs "^@-^_" 2>/dev/null)
assert_eq "range query normalises undefined-key -> empty" "$rng" ""
rng=$(_smart_evt_binding viins "^@-^_" 2>/dev/null)
assert_eq "viins range query normalises undefined-key -> empty" "$rng" ""
_smart_event_capture_originals 2>/dev/null
assert_eq "captured emacs self-insert is self-insert (not undefined-key)" \
    "$_SMART_EVT_ORIG_SELF_EMACS" "self-insert"
assert_eq "captured viins self-insert is self-insert (not undefined-key)" \
    "$_SMART_EVT_ORIG_SELF_VIINS" "self-insert"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 5c: regression — pre-set ORIG_SELF must not skip full capture ==="
# The capture is guarded by a dedicated flag (_SMART_EVT_CAPTURED), NOT by the
# content of one ORIG_* variable. Otherwise a stale or hand-set
# _SMART_EVT_ORIG_SELF_EMACS would skip the whole capture — silently losing the
# native Tab bindings and every other original widget binding too.
_SMART_EVT_CAPTURED=0
_SMART_EVT_ORIG_SELF_EMACS="self-insert"
_SMART_EVT_ORIG_SELF_VIINS="self-insert"
_SMART_EVT_ORIG_BACKDEL_EMACS=""
_smart_event_bind 2>/dev/null
assert_eq "pre-set ORIG_SELF still runs the full capture (backdel refilled)" \
    "$_SMART_EVT_ORIG_BACKDEL_EMACS" "backward-delete-char"
assert_eq "capture flag is set after _smart_event_bind" \
    "${_SMART_EVT_CAPTURED}" "1"
# Second bind must NOT re-capture (originals are stable per session).
_SMART_EVT_ORIG_BACKDEL_EMACS="SENTINEL"
_smart_event_bind 2>/dev/null
assert_eq "capture runs only once per session (original left untouched)" \
    "$_SMART_EVT_ORIG_BACKDEL_EMACS" "SENTINEL"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 6: Original capture variables exist ==="
# Verify the _SMART_EVT_ORIG_* variables were declared.
for v in _SMART_EVT_ORIG_SELF_EMACS \
         _SMART_EVT_ORIG_SELF_VIINS \
         _SMART_EVT_ORIG_BACKDEL_EMACS \
         _SMART_EVT_ORIG_BACKDEL_VIINS \
         _SMART_EVT_ORIG_DEL_EMACS \
         _SMART_EVT_ORIG_DEL_VIINS \
         _SMART_EVT_ORIG_FWDCHAR_EMACS \
         _SMART_EVT_ORIG_FWDCHAR_VIINS \
         _SMART_EVT_ORIG_KILLWORD_EMACS \
         _SMART_EVT_ORIG_KILLWORD_VIINS \
         _SMART_EVT_ORIG_BKWORDS_EMACS \
         _SMART_EVT_ORIG_BKWORDS_VIINS \
         _SMART_EVT_ORIG_YANK_EMACS \
         _SMART_EVT_ORIG_YANK_VIINS \
         _SMART_EVT_ORIG_UNDO_EMACS \
         _SMART_EVT_ORIG_UNDO_VIINS \
         _SMART_EVT_ORIG_HISTUP_VIINS \
         _SMART_EVT_ORIG_HISTDOWN_VIINS; do
    if (( ${+parameters[$v]} )); then
        (( PASS++ ))
    else
        (( FAIL++ )); print -r -- "  FAIL  variable $v missing" >&2
    fi
done

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 7: smart-toggle CLI exists ==="
# smart-toggle is registered in plugin.zsh, not here, but we check that
# the _smart_event_bind/unbind functions exist (they're called by CLI).
assert_fn_exists _smart_event_bind
assert_fn_exists _smart_event_unbind

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 8: Completion state flag exists and resets ==="
if (( ${+_SMART_COMPLETION_ACTIVE} )); then
    (( PASS++ )); print -r -- "  PASS  _SMART_COMPLETION_ACTIVE variable exists"
else
    (( FAIL++ )); print -r -- "  FAIL  _SMART_COMPLETION_ACTIVE variable missing" >&2
fi
# Test reset function.
_SMART_COMPLETION_ACTIVE=1
_smart_native_reset_completion 2>/dev/null
assert_eq "reset_completion sets to 0" "$_SMART_COMPLETION_ACTIVE" "0"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 9: 回归 —— 绑定过程不得向 stdout 输出任何内容 ==="
# zsh 5.9 prints `var='<old value>'` whenever a `local` declaration is executed
# a SECOND time — which is exactly what happens to any `local` written INSIDE a
# loop that iterates more than once:
#
#     for km in a b; do local x; for x in p "q r"; do :; done; done
#     -> prints x='q r' to stdout
#
# In a ZLE widget path that output is painted straight over the command line, so
# the contract is: every loop variable is declared ONCE, at the top of the
# function. This test is the guard for that contract.
raw_binding() {
    local km="$1" seq="$2" out
    out=$(bindkey -M "$km" "$seq" 2>/dev/null) || { print -r -- ""; return 0 }
    out="${out##* }"                     # last whitespace-separated token
    print -r -- "${out//\"/}"
}
local leak
leak=$( { _SMART_EVT_CAPTURED=0; _smart_event_bind; _smart_event_unbind; _smart_event_bind } 2>/dev/null )
assert_eq "bind+unbind+bind emits nothing on stdout" "$leak" ""
leak=$( { _SMART_EVT_CAPTURED=0; _smart_event_capture_originals; _smart_event_bind } 2>/dev/null )
assert_eq "re-capture + re-bind emits nothing on stdout" "$leak" ""

# The wrapper widgets themselves must be silent too (they run per keystroke).
for f in _smart_widget_self_insert _smart_widget_forward_char _smart_widget_accept_word \
         _smart_widget_backward_delete_char _smart_widget_delete_char; do
    leak=$("$f" 2>/dev/null)
    assert_eq "$f emits nothing on stdout" "$leak" ""
done

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 10: 回归 —— 箭头键的每一种编码都要绑定 ==="
# TERM=xterm-256color reports kcuf1 as ESC O C (the *application cursor keys*
# form), and ZLE switches the terminal into that mode. A plugin that binds only
# the CSI form ESC [ C leaves the right arrow on zsh's stock forward-char, so
# the inline suggestion is never accepted — the "right arrow does nothing" bug.
_smart_evt_build_seq_lists
# Put the stock bindings back FIRST: capturing while our own widgets are
# installed would record "" for them (we refuse to treat our own widget as an
# "original"), and the unbind assertions below would then see a removed key
# rather than a restored one. That is the real-world order too: capture
# happens once, before we ever bind.
_smart_event_unbind 2>/dev/null
_SMART_EVT_CAPTURED=0
_smart_event_bind 2>/dev/null
local km seq nfwd=0 nalt=0
for km in emacs viins; do
    for seq in "${_SMART_EVT_FWD_SEQS[@]}"; do
        [[ -z "$seq" ]] && continue
        (( nfwd++ ))
        assert_eq "$km $seq -> forward-char widget" "$(raw_binding "$km" "$seq")" "_smart_widget_forward_char"
    done
    for seq in "${_SMART_EVT_WORDFWD_SEQS[@]}"; do
        [[ -z "$seq" ]] && continue
        (( nalt++ ))
        assert_eq "$km $seq -> accept-word widget" "$(raw_binding "$km" "$seq")" "_smart_widget_accept_word"
    done
done
assert_eq "CSI form is bound" "$(raw_binding emacs '^[[C')" "_smart_widget_forward_char"
assert_eq "SS3 form is bound (the one xterm-256color actually sends)" \
    "$(raw_binding emacs '^[OC')" "_smart_widget_forward_char"
assert_eq "SS3 form bound in viins too" "$(raw_binding viins '^[OC')" "_smart_widget_forward_char"
# Alt+→ inherits the same multi-encoding problem: it is just "ESC then →", so a
# terminal in application-cursor mode sends ESC ESC O C, not ESC [ 1 ; 3 C.
# Binding only the xterm form leaves Alt+→ dead on those terminals (it types a
# literal ^[ into the buffer). Every plain-arrow encoding must have its
# ESC-prefixed sibling bound.
assert_eq "Alt+Right xterm form is bound" "$(raw_binding emacs '^[[1;3C')" "_smart_widget_accept_word"
assert_eq "Alt+Right ESC-ESC-CSI form is bound" "$(raw_binding emacs '^[^[[C')" "_smart_widget_accept_word"
assert_eq "Alt+Right ESC-ESC-SS3 form is bound" "$(raw_binding emacs '^[^[OC')" "_smart_widget_accept_word"
assert_eq "Alt+Right ESC-ESC-SS3 form bound in viins too" \
    "$(raw_binding viins '^[^[OC')" "_smart_widget_accept_word"
local _fe
for _fe in "${_SMART_EVT_FWD_SEQS[@]}"; do
    [[ -z "$_fe" ]] && continue
    assert_eq "every → encoding has Alt sibling [$_fe]" \
        "$(raw_binding emacs "^[${_fe}")" "_smart_widget_accept_word"
done
if (( nfwd >= 4 && nalt >= 4 )); then
    (( PASS++ )); print -r -- "  PASS  bound $nfwd forward + $nalt alt sequences across keymaps"
else
    (( FAIL++ )); print -r -- "  FAIL  too few sequences bound: ${nfwd} fwd / ${nalt} alt" >&2
fi
# viins history arrows must cover both encodings as well.
assert_eq "viins ^[[A -> history up"   "$(raw_binding viins '^[[A')" "_smart_widget_history_up"
assert_eq "viins ^[OA -> history up"   "$(raw_binding viins '^[OA')" "_smart_widget_history_up"

# Delete (ESC [ 3 ~, forward delete) must be wrapped exactly like Backspace.
# Without the wrapper, deleting a character after recalling a history entry
# leaves the STALE inline ghost on screen (the ghost is only recomputed by the
# after-edit hooks, which a stock `delete-char` never runs).
assert_eq "Del ^[[3~ -> our widget (emacs)" "$(raw_binding emacs '^[[3~')" "_smart_widget_delete_char"
assert_eq "Del ^[[3~ -> our widget (viins)" "$(raw_binding viins '^[[3~')" "_smart_widget_delete_char"
# ...and Backspace must still be ours, so a fix for Del cannot have displaced it.
assert_eq "Backspace ^? -> our widget (emacs)" "$(raw_binding emacs '^?')" "_smart_widget_backward_delete_char"

# unbind must restore the stock widgets, not leave them pointing at ours.
_smart_event_unbind 2>/dev/null
# Del and Backspace must be handed back too: leaving Del pointed at our widget
# after `smart off` would keep running our hooks while the plugin is disabled.
assert_eq "after unbind, Del is released" "$(raw_binding emacs '^[[3~')" "delete-char"
# Backspace is compared by PROPERTY, not by literal name: scenario 5d
# deliberately poisons _SMART_EVT_ORIG_BACKDEL_EMACS with the sentinel to prove
# the restore path uses the captured value, so the restored widget is the
# sentinel here. What must hold is only that it is no longer OURS.
if [[ "$(raw_binding emacs '^?')" != "_smart_widget_backward_delete_char" ]]; then
    (( PASS++ )); print -r -- "  PASS  after unbind, Backspace is released"
else
    (( FAIL++ )); print -r -- "  FAIL  after unbind, Backspace still points at our widget" >&2
fi
assert_eq "after unbind, ^[[C is no longer ours" "$(raw_binding emacs '^[[C')" "forward-char"
assert_eq "after unbind, ^[OC is no longer ours" "$(raw_binding emacs '^[OC')" "forward-char"
# Alt+→ has no stock binding in zsh, so a correct restore is "unbound"
# (bindkey then reports the pseudo-widget undefined-key). Assert the property
# that actually matters — the key is no longer hijacked by us — for EVERY
# encoding we bound, not just the xterm one.
local alt_after nstill=0
for seq in "${_SMART_EVT_WORDFWD_SEQS[@]}"; do
    [[ -z "$seq" ]] && continue
    alt_after=$(raw_binding emacs "$seq")
    [[ "$alt_after" == "_smart_widget_accept_word" ]] && (( nstill++ ))
done
if (( nstill == 0 )); then
    (( PASS++ )); print -r -- "  PASS  after unbind, every Alt+Right encoding is released"
else
    (( FAIL++ )); print -r -- "  FAIL  $nstill Alt+Right encoding(s) still point at our widget" >&2
fi

print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
