# lib/engine/menu.zsh
#
# Type-to-popup completion menu — the zsh-autocomplete half of this plugin,
# implemented natively on top of the user's own compsys.
#
# WHAT IT DOES
#   Every time the buffer is edited we run a *listing* completion for the word
#   under the cursor. If the completion has >= SMART_MENU_MIN_MATCHES
#   candidates, the list is drawn below the line — while you type, without
#   pressing Tab. The list re-computes on every keystroke, so it shrinks and
#   grows with the prefix. When the prefix narrows to a single candidate the
#   list is dropped and the inline (grey) suggestion takes over.
#
# WHY IT DOES NOT CONFLICT WITH THE INLINE SUGGESTION
#   The completion list and the POSTDISPLAY ghost share the screen area below
#   the line, and any plain `zle -R` redraw wipes the list. So the order is
#   fixed: render the ghost FIRST (POSTDISPLAY + region_highlight), then run
#   the listing completion, whose own redraw paints line+ghost+list together.
#   Nothing redraws after that. See _smart_menu_tick.
#
# WHY IT DOES NOT TOUCH compinit
#   We never call compinit/compdef. We only borrow the completion *result* via
#   a private completion widget (`zle -C _smart_menu_list list-choices ...`)
#   whose function reads `compstate[nmatches]` and decides whether the list is
#   shown. If the user never ran compinit, the whole module is a no-op.
#
# KILL SWITCH
#   SMART_MENU=false          disable entirely (inline suggestion still works)
#   SMART_MENU_MIN_PREFIX=n   min chars in an ARGUMENT word before listing (1)
#   SMART_MENU_MIN_PREFIX_CMD=n  min chars in the COMMAND word (2)
#   SMART_MENU_MIN_MATCHES=n  don't list unless there are at least n (2)
#   SMART_MENU_MAX_MATCHES=n  don't list when there are more than n (100)
#   SMART_MENU_HISTORY_KEYS=true  ↑/↓ prefix-search history (off by default)
#   SMART_RECENT_PATHS=false  drop recent directories + `cd ` empty-word listing
#   or, at runtime:  smart-menu off | on | status
#
# THROTTLE
#   OFF by default (SMART_MENU_COOLDOWN_KEYS=0), so the list always matches what
#   you typed. The mechanism exists for persistently expensive completions: a
#   listing at or above SMART_MENU_SLOW_MS (250) then buys a cool-down of
#   SMART_MENU_COOLDOWN_KEYS edits. Skipping an edit also drops the list that was
#   on screen, which is why it is off: the only spike we measured is a one-off
#   ~180ms when a completion subsystem loads, and throttling that just removes
#   the popup from the first command of the session.
#
# DEBUGGING
#   SMART_MENU_DEBUG=/tmp/zsc-menu.log logs every tick decision.
#
# This module knows about state + compsys. It does NOT know about history.

emulate -L zsh
setopt extended_glob no_warn_create_global

# Make completion lists scrollable instead of dumping every line. zsh/complist
# is what turns a long candidate list into a scrollable panel (one screenful at
# a time, paged with Space) instead of dumping every row at once.
#
# DO NOT scope-assign LISTMAX around the listing call. It looks like the obvious
# way to stop zsh asking "do you wish to see all N possibilities (M lines)?",
# but it corrupts ZLE's next input read and silently EATS ONE KEYSTROKE per
# listing: with it, typing `git status` leaves `gitstatus` in the buffer and the
# shell runs the wrong command. It was measured A/B across short and long lists
# (both directions broken) and is permanently gone. The prompt is prevented
# instead by SMART_MENU_MAX_MATCHES (see _smart_menu_decide_list), which simply
# declines to draw a list that big.
zmodload zsh/complist 2>/dev/null

# Defaults live in lib/config.zsh (the single source of truth).
# Result of the last listing run. Read by smart-menu status and the tests.
typeset -gi _SMART_MENU_NMATCHES=0
typeset -gi _SMART_MENU_LISTED=0
typeset -gi _SMART_MENU_TICKS=0
typeset -gi _SMART_MENU_SKIPS=0
typeset -gi _SMART_MENU_COOLDOWN=0
typeset -gi _SMART_MENU_LAST_MS=0
# 1 when the last listing was suppressed because it exceeded SMART_MENU_MAX_MATCHES.
typeset -gi _SMART_MENU_TRUNCATED=0

# Timing. zsh/datetime gives us sub-second wall clock; if the module is
# unavailable we simply never throttle (correct, just slower on hot paths).
# NOTE: EPOCHREALTIME is a PARAMETER, so the feature must be requested with
# the `p:` prefix. `b:EPOCHREALTIME` is rejected ("no such feature") and leaves
# the parameter undefined, which would silently disable all throttling.
zmodload -F zsh/datetime p:EPOCHREALTIME 2>/dev/null
_smart_menu_now_ms() {
    local t="${EPOCHREALTIME:-}"
    [[ -z "$t" ]] && { print -r -- 0; return 0; }
    t="${t/./}"                      # 1789465211.123456 -> 1789465211123456
    print -r -- "${t[1,13]}"         # first 13 digits = milliseconds
}
_smart_menu_have_clock() { [[ -n "${EPOCHREALTIME:-}" ]] }

# Optional decision trace. Set SMART_MENU_DEBUG=/path/to/log to append one line
# per tick (why it was skipped, what it cost, how many matched). This is the
# only way to answer "why is there no popup?" without guessing — the visible
# screen cannot distinguish "gate said no" from "cooldown ate it" from
# "completion found 1 match". Zero cost when unset (a single -n test).
_smart_menu_dbg() {
    [[ -n "${SMART_MENU_DEBUG:-}" ]] || return 0
    print -r -- "$*" >> "$SMART_MENU_DEBUG" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------

# _smart_menu_enabled -- 0 if the menu channel is allowed to run at all.
_smart_menu_enabled() {
    case "${SMART_MENU:-true}" in false|no|off|0|disabled) return 1 ;; esac
    (( ${_SMART_STATE[enabled]:-1} == 1 )) || return 1
    return 0
}

# _smart_menu_word -- the whitespace-delimited word under the cursor.
# Cheap (no regexp over the whole buffer, no compsys call).
_smart_menu_word() {
    print -r -- "${LBUFFER##*[[:space:]]}"
}

# _smart_menu_is_command_word -- are we completing the first word of the line?
_smart_menu_is_command_word() {
    local before="${LBUFFER%${LBUFFER##*[[:space:]]}}"
    [[ -z "${before//[[:space:]]/}" ]]
}

# _smart_menu_should_list -- all preconditions for running completion.
_smart_menu_should_list() {
    _smart_menu_enabled || return 1
    # compsys has to be alive; otherwise there is nothing to list.
    (( ${+functions[_smart_native_have_compinit]} )) || return 1
    _smart_native_have_compinit || return 1

    local w min
    w="$(_smart_menu_word)"
    if _smart_menu_is_command_word; then
        min="${SMART_MENU_MIN_PREFIX_CMD:-2}"
    elif (( ${+functions[_smart_recent_cd_empty_ok]} )) && _smart_recent_cd_empty_ok; then
        # `cd ` / `pushd ` with recent dirs enabled: list immediately, because
        # "which directories have I been in?" is exactly the question being
        # asked there. Deliberately narrower than SMART_MENU_MIN_PREFIX=0,
        # which would dump every candidate after every space.
        min=0
    else
        min="${SMART_MENU_MIN_PREFIX:-1}"
    fi
    (( ${#w} >= min )) || return 1
    (( ${#w} <= ${SMART_MENU_MAX_PREFIX:-64} )) || return 1
    return 0
}

# ---------------------------------------------------------------------------
# The listing completion widget
# ---------------------------------------------------------------------------

# _smart_menu_decide_list <nmatches>
#
# Pure decision used by the listing widget: should the candidate list be drawn?
#   0 = draw the list
#   1 = suppress it
# A match count is suppressed when it is below SMART_MENU_MIN_MATCHES (a lone
# candidate is already shown as inline ghost text) or above SMART_MENU_MAX_MATCHES
# (a gigantic directory listing — suppress it so we never re-render thousands of
# rows on every keystroke). The cap is ALSO what keeps zsh's interactive
# "do you wish to see all N possibilities (M lines)?" confirmation from ever
# appearing: that prompt fires for lists longer than the screen, so simply never
# drawing such a list is the robust fix. (Scoping LISTMAX instead eats
# keystrokes — see the note at the top of this file.)
# Split out of the completer so it is unit-testable without a compsys/ZLE
# context (same idea as _smart_menu_note_cost).
_smart_menu_decide_list() {
    local n="$1"
    (( n >= ${SMART_MENU_MIN_MATCHES:-2} )) || return 1
    if (( ${SMART_MENU_MAX_MATCHES:-0} > 0 && n > ${SMART_MENU_MAX_MATCHES} )); then
        return 1
    fi
    return 0
}

# _smart_menu_list_main -- the completer function behind `zle -C`.
#
# Runs the user's normal completion, then takes control of the *display*:
#   decide-list says draw -> force the list, never insert
#   otherwise              -> suppress the list, never insert
# `compstate` is only writable from in here, which is exactly why the list is
# driven by a completion widget instead of calling `zle list-choices` naked.
_smart_menu_list_main() {
    _main_complete "$@"
    _SMART_MENU_NMATCHES="${compstate[nmatches]:-0}"
    compstate[insert]=''          # this channel only displays, never inserts
    if _smart_menu_decide_list "$_SMART_MENU_NMATCHES"; then
        compstate[list]='list'
        _SMART_MENU_LISTED=1
        _SMART_MENU_TRUNCATED=0
    else
        # Suppressed: either below the minimum (ghost takes over) or above the
        # cap (huge dir — the popup would be unreadable, and declining to draw
        # it is also what keeps zsh's "do you wish to see all N possibilities"
        # prompt out of the way). Note which, for status output.
        compstate[list]=''
        _SMART_MENU_LISTED=0
        if (( ${SMART_MENU_MAX_MATCHES:-0} > 0 && _SMART_MENU_NMATCHES > ${SMART_MENU_MAX_MATCHES} )); then
            _SMART_MENU_TRUNCATED=1
        else
            _SMART_MENU_TRUNCATED=0
        fi
    fi
    return 0
}
zle -C _smart_menu_list list-choices _smart_menu_list_main 2>/dev/null

# ---------------------------------------------------------------------------
# Completion-strategy probe (the `completion` half of SMART_SUGGEST_STRATEGY)
# ---------------------------------------------------------------------------

# _smart_menu_probe_main -- the completer behind the unambiguous-prefix probe.
#
# Runs the user's completion and lets zsh insert ONLY the unambiguous prefix
# (the part Tab would add before it had to choose). The caller then diffs
# $BUFFER to learn what completion proposed and reverts it, so the text becomes
# a *suggestion* rather than an edit.
#
# compstate[list] is cleared: this channel proposes text, it never paints a list
# (drawing belongs to _smart_menu_list, so the two can never fight over it).
_smart_menu_probe_main() {
    _main_complete "$@"
    compstate[insert]='unambiguous'
    compstate[list]=''
    return 0
}
zle -C _smart_menu_probe complete-word _smart_menu_probe_main 2>/dev/null

# _smart_menu_completion_suffix -- echo what completion would append, or "".
#
# MUST be called from inside a ZLE widget (it runs `zle`). Read-only with
# respect to the user's line: the buffer is restored before returning.
_smart_menu_completion_suffix() {
    (( ${+widgets[_smart_menu_probe]} )) || { print -r -- ""; return 0; }
    # Only meaningful at end of line — completion would replace the word under
    # the cursor, and we cannot express that as a pure suffix.
    (( CURSOR == ${#BUFFER} )) || { print -r -- ""; return 0; }
    _smart_native_have_compinit 2>/dev/null || { print -r -- ""; return 0; }

    local before="$BUFFER" cur="$CURSOR" after
    zle _smart_menu_probe 2>/dev/null
    after="$BUFFER"
    BUFFER="$before"          # this channel proposes, it never edits
    CURSOR="$cur"
    [[ "$after" == "$before"* ]] || { print -r -- ""; return 0; }
    print -r -- "${after#$before}"
    return 0
}

# ---------------------------------------------------------------------------
# Tick — called by the event layer after every buffer edit
# ---------------------------------------------------------------------------

# _smart_menu_note_cost <cost-ms> -- apply the throttle policy to one listing.
#
# Split out of _smart_menu_tick so the policy is unit-testable: this is the rule
# that silently ate the popup (a 50ms threshold tripped by a one-off 180ms cold
# load, with a 3-edit cool-down), and an untestable rule is how it survived.
_smart_menu_note_cost() {
    local cost="$1" slow="${SMART_MENU_SLOW_MS:-250}" keys="${SMART_MENU_COOLDOWN_KEYS:-0}"
    _SMART_MENU_LAST_MS="$cost"
    if (( keys > 0 && slow > 0 && cost >= slow )); then
        _SMART_MENU_COOLDOWN="$keys"
        _smart_menu_dbg "list cost=${cost}ms SLOW -> cooldown=$keys"
        return 0
    fi
    _smart_menu_dbg "list cost=${cost}ms"
    return 0
}

# _smart_menu_tick
#
# ORDER IS LOAD-BEARING:
#   1. show the ghost (POSTDISPLAY + region_highlight) — the event layer has
#      already done it, but we re-assert it because a previous listing may have
#      dropped our region_highlight entry.
#   2. run the listing completion. Its redraw paints the line (ghost included)
#      and the candidate list in one go.
# Any redraw after step 2 deletes the list, so there is none.
#
# THROTTLING: measured cost is 10-30ms for every ordinary listing, so the
# throttle is OFF by default (SMART_MENU_COOLDOWN_KEYS=0) and the list always
# matches the current word. Enable it only for a persistently expensive
# completion: a listing at or above SMART_MENU_SLOW_MS then buys a cool-down of
# SMART_MENU_COOLDOWN_KEYS edits. Weigh the cost of skipping: the skipped edit
# does not repaint, so the list that was on screen is gone for that keystroke.
# The policy itself lives in _smart_menu_note_cost, above.
_smart_menu_tick() {
    _smart_menu_should_list || { _smart_menu_dbg "skip gate word=[$(_smart_menu_word)]"; return 0; }

    # Fallback for the completer wiring: if the bootstrap precmd ran before the
    # user's compinit (some plugin managers load us first), join the chain now —
    # we are provably inside the completion path, so compsys is alive.
    # One integer test per tick; the install itself is idempotent.
    if (( ${+functions[_smart_recent_install]} )) && (( ! ${_SMART_RECENT_INSTALLED:-0} )); then
        _smart_recent_install 2>/dev/null
    fi

    if (( _SMART_MENU_COOLDOWN > 0 )); then
        (( _SMART_MENU_COOLDOWN-- ))
        (( _SMART_MENU_SKIPS++ ))
        _smart_menu_dbg "skip cooldown left=$_SMART_MENU_COOLDOWN word=[$(_smart_menu_word)]"
        return 0
    fi

    (( ++_SMART_MENU_TICKS ))
    _smart_display_show 2>/dev/null

    local t0=$(_smart_menu_now_ms)
    _SMART_MENU_LISTED=0
    # NOTE: no LISTMAX juggling here. It used to be scoped to -1 around this
    # call to suppress zsh's "do you wish to see all N possibilities" prompt;
    # that corrupts ZLE's next input read and eats one keystroke per listing.
    # The prompt is prevented by SMART_MENU_MAX_MATCHES instead (see above).
    zle _smart_menu_list 2>/dev/null
    (( _SMART_MENU_LISTED )) || {
        # Nothing was drawn. Report WHICH gate refused: "below the minimum" and
        # "over the cap" look identical on screen but have opposite fixes, and
        # conflating them in the log (as this used to) misleads debugging.
        if (( ${_SMART_MENU_TRUNCATED:-0} == 1 )); then
            _smart_menu_dbg "list n=${_SMART_MENU_NMATCHES} over cap=${SMART_MENU_MAX_MATCHES:-0} -> no list"
        else
            _smart_menu_dbg "list n=${_SMART_MENU_NMATCHES} below min=${SMART_MENU_MIN_MATCHES:-2} -> no list"
        fi
        return 0
    }
    if _smart_menu_have_clock; then
        _smart_menu_note_cost $(( $(_smart_menu_now_ms) - t0 ))
    fi
    return 0
}

# _smart_menu_clear -- drop the candidate list bookkeeping.
_smart_menu_clear() {
    _SMART_MENU_LISTED=0
    _SMART_MENU_NMATCHES=0
    return 0
}

# ---------------------------------------------------------------------------
# Runtime CLI
# ---------------------------------------------------------------------------
smart-menu() {
    case "${1:-status}" in
        on|enable|1|true)
            SMART_MENU=true
            print -r -- "smart-menu: on (min prefix: cmd=${SMART_MENU_MIN_PREFIX_CMD} arg=${SMART_MENU_MIN_PREFIX}, min matches=${SMART_MENU_MIN_MATCHES})"
            ;;
        off|disable|0|false)
            SMART_MENU=false
            _smart_menu_clear
            _smart_display_clear 2>/dev/null
            zle -R 2>/dev/null
            print -r -- "smart-menu: off (inline suggestion is unaffected)"
            ;;
        toggle)
            if _smart_menu_enabled; then smart-menu off; else smart-menu on; fi
            ;;
        status|*)
            if _smart_menu_enabled; then
                print -r -- "smart-menu: on"
            else
                print -r -- "smart-menu: off"
            fi
            print -r -- "  min prefix (command/arg): ${SMART_MENU_MIN_PREFIX_CMD}/${SMART_MENU_MIN_PREFIX}"
            print -r -- "  min matches:              ${SMART_MENU_MIN_MATCHES}"
            print -r -- "  max matches (cap):        ${SMART_MENU_MAX_MATCHES:-0}$( (( ${SMART_MENU_MAX_MATCHES:-0} == 0 )) && print -r -- ' (uncapped)' || print -r -- ' (bigger lists are suppressed)')"
            if [[ "${SMART_MENU_HISTORY_KEYS:-false}" == "true" ]]; then
                print -r -- "  history keys:             on (↑/↓ prefix-search history when the line is non-empty)"
            else
                print -r -- "  history keys:             off (↑/↓ keep native history navigation)"
            fi
            if (( ${SMART_MENU_COOLDOWN_KEYS:-0} > 0 )); then
                print -r -- "  throttle:                 on (slow >= ${SMART_MENU_SLOW_MS}ms -> skip ${SMART_MENU_COOLDOWN_KEYS})"
            else
                print -r -- "  throttle:                 off (list always matches the current word)"
            fi
            print -r -- "  last listing:             matches=${_SMART_MENU_NMATCHES} listed=${_SMART_MENU_LISTED} cost=${_SMART_MENU_LAST_MS}ms"
            if (( ${_SMART_MENU_TRUNCATED:-0} == 1 )); then
                print -r -- "  note:                    last popup suppressed (matches > SMART_MENU_MAX_MATCHES)"
            fi
            print -r -- "  listings/skipped:         ${_SMART_MENU_TICKS}/${_SMART_MENU_SKIPS}"
            ;;
    esac
    return 0
}
