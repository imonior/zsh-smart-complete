#!/usr/bin/env zsh
# tests/test-display.zsh
#
# Unit tests for the display layer (lib/display/display.zsh).
#
# This is the only module that touches ZLE's rendering surface, which also makes
# it the easiest one to break silently: a wrong region_highlight entry costs the
# user their ghost colour, and a forgotten one costs them another plugin's
# highlighting. Neither shows up in a behavioural test of the suggestions
# themselves.
#
# Everything here runs in a plain script, which the module supports by design:
# it only assigns $BUFFER/$CURSOR/$POSTDISPLAY/$PREDISPLAY/$region_highlight and
# never calls `zle`. $SMART_SUGGEST_COLOR is pinned so the expected
# region_highlight strings are exact — the auto-colour policy has its own tests
# in test-menu.zsh and is not duplicated here.

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

SMART_SUGGEST_COLOR="fg=8"
SMART_INLINE="true"

# Our single entry, plus how many of the entries on screen are ours. "Ours" is
# decided by the module itself, not by assuming the memo is there: on a zsh that
# cannot carry one, the identity is the entry's own text.
_own_rh=""
_own_n=0
_scan_rh() {
    local r
    _own_rh=""; _own_n=0
    for r in "${region_highlight[@]}"; do
        _smart_display_rh_ours "$r" && { ((_own_n++)); _own_rh="$r"; }
    done
}
_foreign_n() {
    local r n=0
    for r in "${region_highlight[@]}"; do
        _smart_display_rh_ours "$r" || (( n++ ))
    done
    print -r -- "$n"
}
# The entry text _smart_display_rh_put is supposed to produce here, i.e. the two
# shapes _SMART_RH_MEMO_OK picks between. Pinned in both directions so a change
# to the gate cannot quietly make one of them untested.
_want() {
    if (( _SMART_RH_MEMO_OK )); then
        print -r -- "$1 $2 fg=8  memo=${_SMART_RH_MARKER}"
    else
        print -r -- "$1 $2 fg=8"
    fi
}
# A blank screen: no buffer, no ghost, no suggestions, no highlight.
_reset_screen() {
    BUFFER=""; CURSOR=0; POSTDISPLAY=""; PREDISPLAY=""
    # Through the module, so it also forgets which entry was ours -- a bare
    # region_highlight=() would leave the previous scenario's identity behind.
    _smart_display_rh_drop
    region_highlight=()
    _smart_state_set suggestion.text ""
    _smart_state_set enabled 1
}

print -r -- "=== 场景 1: rh_put / rh_drop ==="
_reset_screen
region_highlight=("0 3 bold fg=yellow")
_smart_display_rh_put 5 10
_scan_rh
assert_eq "one entry of ours"        "$_own_n"    "1"
assert_eq "exact entry text"         "$_own_rh"   "$(_want 5 10)"
assert_eq "foreign entry untouched"  "$(_foreign_n)" "1"
# A second put replaces ours rather than stacking: the entries used to pile up
# one per redraw, and the leftovers are what killed the colour.
_smart_display_rh_put 2 4
_scan_rh
assert_eq "re-put does not stack"    "$_own_n"    "1"
assert_eq "re-put moved the range"   "$_own_rh"   "$(_want 2 4)"
assert_eq "foreign entry still there" "$(_foreign_n)" "1"
_smart_display_rh_drop
_scan_rh
assert_eq "drop removes ours"        "$_own_n"    "0"
assert_eq "drop keeps foreign"       "$(_foreign_n)" "1"
assert_rc "drop without our entry is fine" 0 _smart_display_rh_drop

print -r -- ""
print -r -- "=== 场景 2: reassert_rh (the post-list colour repair) ==="
# This is what a completion list leaves behind: our range clipped to the end of
# BUFFER, i.e. zero-length, i.e. no colour. Written through the module so it has
# the shape this zsh gives an entry of ours.
_reset_screen
_smart_display_rh_put 5 5
assert_rc "no ghost -> no-op" 0 _smart_display_reassert_rh
_scan_rh
assert_eq "untouched while POSTDISPLAY is empty" "$_own_rh" "$(_want 5 5)"
BUFFER="git s"; POSTDISPLAY="tatus"
_smart_display_reassert_rh
_scan_rh
assert_eq "re-clipped range restored" "$_own_rh" "$(_want 5 10)"
assert_eq "still exactly one of ours" "$_own_n"  "1"
region_highlight=("0 3 bold fg=yellow")
_smart_display_rh_put 5 5
BUFFER="ls"; POSTDISPLAY=" -la"
_smart_display_reassert_rh
_scan_rh
assert_eq "reassert from an empty BUFFER" "$_own_rh" "$(_want 2 6)"
assert_eq "reassert leaves foreign alone" "$(_foreign_n)" "1"

print -r -- ""
print -r -- "=== 场景 3: show ==="
_reset_screen
_smart_state_set suggestion.text "git status"
BUFFER="git s"; CURSOR=5
assert_rc "show" 0 _smart_display_show
assert_eq "ghost text"      "$POSTDISPLAY" "tatus"
_scan_rh
assert_eq "ghost is coloured" "$_own_rh" "$(_want 5 10)"
# Two keystrokes in a row must not leave two entries behind.
_smart_display_show
_scan_rh
assert_eq "still one entry after a second show" "$_own_n" "1"
# A suggestion equal to what is already typed has nothing to show.
_smart_state_set suggestion.text "git s"
_smart_display_show
assert_eq "identical suggestion shows nothing" "$POSTDISPLAY" ""
_scan_rh
assert_eq "and leaves no entry"                "$_own_n"      "0"
# A suggestion that does not extend BUFFER would need an edit, not a ghost.
_reset_screen
_smart_state_set suggestion.text "docker ps"
BUFFER="git s"
_smart_display_show
assert_eq "non-prefix suggestion is not shown" "$POSTDISPLAY" ""
# The two kill switches.
_reset_screen
_smart_state_set suggestion.text "git status"
BUFFER="git s"
_smart_state_set enabled 0
_smart_display_show
assert_eq "disabled plugin shows nothing" "$POSTDISPLAY" ""
assert_eq "disabled plugin leaves no highlight" "$(_foreign_n)" "0"
_smart_state_set enabled 1
SMART_INLINE="false"
_smart_display_show
assert_eq "SMART_INLINE=false shows nothing" "$POSTDISPLAY" ""
SMART_INLINE="true"
# Clearing must also undo a ghost that was on screen.
assert_eq "clear after off-switch"        "$(_smart_display_clear; print -r -- "$POSTDISPLAY")" ""
# With the cursor mid-line the tail is still the part BUFFER is missing.
_reset_screen
_smart_state_set suggestion.text "git status --short"
BUFFER="git status"; CURSOR=3
_smart_display_show
assert_eq "cursor mid-line: tail of BUFFER" "$POSTDISPLAY" " --short"
# A BUFFER containing glob magic must be compared as text: the history line
# `git * push` is an ordinary command, not a pattern.
_reset_screen
_smart_state_set suggestion.text "git * push"
BUFFER="git *"
_smart_display_show
assert_eq "glob magic in BUFFER is literal" "$POSTDISPLAY" " push"

print -r -- ""
print -r -- "=== 场景 4: clear ==="
_reset_screen
_smart_state_set suggestion.text "git status"
BUFFER="git s"
_smart_display_show
region_highlight+=("0 3 bold fg=yellow")
PREDISPLAY="leftover"
assert_rc "clear" 0 _smart_display_clear
assert_eq "clear empties POSTDISPLAY" "$POSTDISPLAY" ""
assert_eq "clear empties PREDISPLAY"  "$PREDISPLAY"  ""
_scan_rh
assert_eq "clear drops our entry"     "$_own_n"      "0"
assert_eq "clear keeps foreign"       "$(_foreign_n)" "1"

print -r -- ""
print -r -- "=== 场景 5: update ==="
_reset_screen
_smart_state_set suggestion.text "git commit -a"
BUFFER="git comm"
assert_rc "update" 0 _smart_display_update
assert_eq "update renders the ghost"      "$POSTDISPLAY" "it -a"
_scan_rh
assert_eq "update colours it"             "$_own_n"      "1"
_smart_state_set suggestion.text ""
_smart_display_update
assert_eq "update with no suggestion clears" "$POSTDISPLAY" ""
_scan_rh
assert_eq "and drops the entry"              "$_own_n"      "0"

print -r -- ""
print -r -- "=== 场景 6: accept_partial ==="
_reset_screen
_smart_state_set suggestion.text "git status"
BUFFER="git s"; CURSOR=5
region_highlight=("0 3 bold fg=yellow")
assert_rc "accept_partial" 0 _smart_display_accept_partial
assert_eq "buffer takes the suggestion" "$BUFFER" "git status"
assert_eq "cursor moves to the end"     "$CURSOR" "10"
assert_eq "ghost is gone"               "$POSTDISPLAY" ""
_scan_rh
assert_eq "accept clears our highlight" "$_own_n" "0"
assert_eq "accept keeps foreign"        "$(_foreign_n)" "1"
# Not a prefix: the suggestion is dropped rather than spliced in.
_reset_screen
_smart_state_set suggestion.text "docker ps"
BUFFER="git s"
assert_rc "accept_partial non-prefix" 0 _smart_display_accept_partial
assert_eq "non-prefix leaves BUFFER"   "$BUFFER" "git s"
# Nothing pending: nothing changes.
_reset_screen
BUFFER="ls -l"; CURSOR=2
assert_rc "accept_partial with no suggestion" 0 _smart_display_accept_partial
assert_eq "no suggestion leaves BUFFER"        "$BUFFER" "ls -l"
assert_eq "no suggestion leaves CURSOR"        "$CURSOR" "2"

print -r -- ""
print -r -- "=== 场景 7: accept_word guards and cleanup ==="
# The word-boundary walk itself belongs to test-menu.zsh; what is covered here
# is the return contract and the rendering cleanup the widget shares with
# accept_partial.
_reset_screen
assert_rc "no suggestion -> 1 (caller falls back)" 1 _smart_display_accept_word
_smart_state_set suggestion.text "docker ps"
BUFFER="git s"
assert_rc "non-prefix -> 1" 1 _smart_display_accept_word
_reset_screen
_smart_state_set suggestion.text "git commit -a"
BUFFER="git"; CURSOR=3
POSTDISPLAY=" commit -a"
region_highlight=("$( _want 3 13)" "0 3 bold fg=yellow")
assert_rc "accept_word" 0 _smart_display_accept_word
_scan_rh
assert_eq "accept_word clears our entry" "$_own_n" "0"
assert_eq "accept_word keeps foreign"    "$(_foreign_n)" "1"
assert_eq "accept_word clears the ghost" "$POSTDISPLAY" ""

print -r -- ""
print -r -- "=== 场景 8: a zsh that cannot carry the memo marker ==="
# The shape of the entry decides whether users see a coloured ghost at all, and
# on a host whose zsh is 5.9+ the real branch never runs. Forced here so both
# shapes are measured on every run, not only on the containers that happen to
# ship an older zsh.
assert_rc "5.9 supports the marker"      0 _smart_display_memo_supported 5.9
assert_rc "5.9.1 supports it"            0 _smart_display_memo_supported 5.9.1
assert_rc "6.0 supports it"              0 _smart_display_memo_supported 6.0
assert_rc "5.8.1 does not"               1 _smart_display_memo_supported 5.8.1
assert_rc "5.7.1 does not"               1 _smart_display_memo_supported 5.7.1
assert_rc "5.10 supports it, not read as 5.1" 0 _smart_display_memo_supported 5.10
assert_rc "a version we cannot read does not" 1 _smart_display_memo_supported r-e-l
_reset_screen
_saved_memo_ok="$_SMART_RH_MEMO_OK"
_SMART_RH_MEMO_OK=0
region_highlight=("0 3 bold fg=yellow")
_smart_display_rh_put 5 10
_scan_rh
assert_eq "one entry of ours"        "$_own_n"  "1"
assert_eq "no marker in it"          "$_own_rh" "5 10 fg=8"
assert_eq "foreign entry untouched"  "$(_foreign_n)" "1"
# Three keystrokes, three different ranges. With no marker the only handle on
# our own entry is the text it has in the array, so a moving range must still
# leave one entry behind rather than one per keystroke.
_smart_display_rh_put 4 9
_smart_display_rh_put 6 10
_scan_rh
assert_eq "no stacking over moving ranges" "$_own_n"  "1"
assert_eq "the last range is the one shown" "$_own_rh" "6 10 fg=8"
assert_eq "and the foreign entry is still there" "$(_foreign_n)" "1"
# Now the list redraw: zsh clips our entry to zero length in place, which
# matches neither the text we recorded (its end moved) nor a marker it never had.
region_highlight=("0 3 bold fg=yellow" "6 6 fg=8")
BUFFER="git st"; POSTDISPLAY="atus"
_smart_display_reassert_rh
_scan_rh
assert_eq "ours is back, spanning the ghost" "$_own_rh" "6 10 fg=8"
assert_eq "exactly one of ours"              "$_own_n"  "1"
assert_eq "the clipped leftover is gone too" "${#region_highlight}" "2"
_smart_display_rh_drop
_scan_rh
assert_eq "drop finds it without a marker" "$_own_n"      "0"
assert_eq "drop keeps foreign"             "$(_foreign_n)" "1"
assert_eq "drop forgets the entry"         "$_SMART_RH_SELF" ""
_SMART_RH_MEMO_OK="$_saved_memo_ok"
_reset_screen

print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
