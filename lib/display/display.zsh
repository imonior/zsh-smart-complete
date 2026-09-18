# lib/display/display.zsh
#
# Display layer.
#
# The ONLY place that touches ZLE terminal rendering. Knows about:
#   $BUFFER, $CURSOR, $region_highlight, $PREDISPLAY, $POSTDISPLAY, zle .
#
# Knows NOTHING about:
#   history, fc, atuin, suggestion scoring, ranking, compinit, compadd.
#
# It reads one piece of data: state.suggestion.text.
# Its job is to put that text after $BUFFER in a "ghost" color, and to
# remove cleanly when asked.
#
# Public API (4 functions):
#   _smart_display_show            -- render region_highlight + POSTDISPLAY
#   _smart_display_clear           -- undo everything above
#   _smart_display_update          -- convenience = compute + show OR clear
#   _smart_display_accept_partial  -- user pressed →; merge suggestion into BUFFER

emulate -L zsh
setopt extended_glob no_warn_create_global

# We mark our slot in region_highlight with a distinct `memo=` token so we can
# remove only our own ranges without clobbering syntax-highlighter plugins
# (fast-syntax-highlighting, zsh-syntax-highlighting, etc.).
#
# `memo=token` is the documented mechanism (zshzle(1) -> region_highlight): the
# token is "preserved verbatim but not parsed in any way", and the manual even
# shows this exact strip-only-our-own-entries idiom.
#
# Do NOT go back to the old `#comment` form. zsh REWRITES the array on every
# redraw and drops everything from the `#` on, so the marker never survives to
# the next keystroke and the filter below silently stops matching. Measured on
# the previous code: entries accumulated one per redraw (8 after 5 keystrokes,
# 171 with a syntax highlighter loaded), and the stale zero-length leftovers
# were what killed the ghost's colour.
_SMART_RH_MARKER="zsh-smart-complete:suggestion"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _smart_display_color -- resolve the color spec for the suggestion ghost.
_smart_display_color() {
    local c="${SMART_SUGGEST_COLOR}"
    [[ -z "$c" ]] && c="fg=8"
    print -r -- "$c"
}

# ---------------------------------------------------------------------------
# region_highlight plumbing
#
# One entry of ours, always at most one, identified by memo=$_SMART_RH_MARKER.
# ---------------------------------------------------------------------------

# _smart_display_rh_put <start> <end> -- (re)write our single entry, dropping a
# previous one of ours and leaving every foreign entry untouched.
_smart_display_rh_put() {
    local color
    color="$(_smart_display_color)"
    local -a rh=("${region_highlight[@]}")
    local -a clean=()
    local r
    for r in "${rh[@]}"; do
        [[ "$r" == *"memo=${_SMART_RH_MARKER}"* ]] && continue
        clean+=("$r")
    done
    clean+=("$1 $2 ${color}  memo=${_SMART_RH_MARKER}")
    region_highlight=("${clean[@]}")
    return 0
}

# _smart_display_rh_drop -- remove our entry, keep everything else.
_smart_display_rh_drop() {
    (( ${+region_highlight} )) || return 0
    local -a rh=("${region_highlight[@]}")
    local -a clean=()
    local r
    for r in "${rh[@]}"; do
        [[ "$r" == *"memo=${_SMART_RH_MARKER}"* ]] && continue
        clean+=("$r")
    done
    region_highlight=("${clean[@]}")
    return 0
}

# _smart_display_reassert_rh -- re-write our entry from the CURRENT POSTDISPLAY
# without redrawing anything. No-op when no ghost is shown.
#
# WHY THIS EXISTS. Drawing a completion LIST makes zsh refresh the line for the
# list, and that refresh rewrites region_highlight with every entry whose range
# reaches into POSTDISPLAY clipped back to the end of BUFFER (measured:
# `5 10 fg=8` -> `5 5 fg=8`). A zero-length entry colours nothing, so the ghost
# lost its colour on exactly the keystrokes that also drew the candidate list —
# i.e. in the default type-to-popup mode, always. Re-writing the entry after the
# listing restores the range before ZLE's final repaint of the widget.
#
# Deliberately NO `zle -R` here: a redraw at this point would erase the list we
# just drew. Writing the array alone is enough.
_smart_display_reassert_rh() {
    [[ -z "$POSTDISPLAY" ]] && return 0
    _smart_display_rh_put "${#BUFFER}" "$(( ${#BUFFER} + ${#POSTDISPLAY} ))"
    return 0
}

# ---------------------------------------------------------------------------
# show / clear
# ---------------------------------------------------------------------------

# _smart_display_show -- show the current suggestion as ghost text.
#
# Strategy (matches what zsh-autosuggestions does but uses a custom
# marker so we can coexist with other region_highlight writers):
#
#   If suggestion is a strict extension of BUFFER (BUFFER is a prefix):
#       * The tail suffix starting at CURSOR is appended via POSTDISPLAY,
#         which makes the cursor show at the correct position and makes
#         →-to-accept trivial (POSTDISPLAY is merged into BUFFER at accept).
#       * We colour the POSTDISPLAY region via region_highlight.
#
#   Else (suggestion exists but doesn't cleanly extend BUFFER, e.g. user
#   typed a mid-word correction):
#       * We clear the display. It's the conservative, non-confusing choice.
_smart_display_show() {
    case "${SMART_INLINE}" in
        false|no|off|0|disabled) _smart_display_clear; return 0 ;;
    esac
    (( $(_smart_state_get enabled 1) == 0 )) && { _smart_display_clear; return 0; }

    local sug
    sug="$(_smart_state_get suggestion.text "")"
    [[ -z "$sug" ]] && { _smart_display_clear; return 0; }

    # Strict prefix extension check: BUFFER must be a prefix of suggestion.
    if [[ "$sug" != "$BUFFER"* ]]; then
        _smart_display_clear
        return 0
    fi

    local suffix="${sug#$BUFFER}"
    [[ -z "$suffix" ]] && { _smart_display_clear; return 0; }

    # 1. POSTDISPLAY carries the visual tail.
    POSTDISPLAY="$suffix"

    # 2. region_highlight colours the POSTDISPLAY region.
    #    POSTDISPLAY starts at offset ${#BUFFER} (0-based, end of BUFFER).
    _smart_display_rh_put "${#BUFFER}" "$(( ${#BUFFER} + ${#suffix} ))"

    return 0
}

# _smart_display_clear -- undo _smart_display_show completely.
_smart_display_clear() {
    POSTDISPLAY=""
    PREDISPLAY=""
    _smart_display_rh_drop
    return 0
}

# ---------------------------------------------------------------------------
# Convenience wrappers used by the event layer.
# ---------------------------------------------------------------------------

# _smart_display_update <buffer>
#   Called after the event layer has run _smart_suggest_compute.
_smart_display_update() {
    _smart_display_show
    zle -R "" "" 2>/dev/null   # force a redraw of the new region_highlight
    return 0
}

# _smart_display_accept_partial
#   User pressed → (forward-char at end of line). Merge the POSTDISPLAY
#   suffix into BUFFER, move cursor, clear display.
_smart_display_accept_partial() {
    local sug
    sug="$(_smart_state_get suggestion.text "")"
    [[ -z "$sug" ]] && return 0

    if [[ "$sug" == "$BUFFER"* ]]; then
        BUFFER="$sug"
        CURSOR="${#BUFFER}"
    fi
    _smart_display_clear
    return 0
}

# _smart_display_accept_word
#   Alt+→ . Merge only the NEXT word of the suggestion into BUFFER and leave
#   the remainder as ghost text (the caller recomputes, so the ghost may also
#   be replaced by a fresh suggestion). A word here is: any leading separator
#   run plus the following non-separator run, i.e. exactly what you would get
#   by typing up to the next word boundary — which is what makes
#   `g`+Alt+→ produce `git ` and not `git`.
#
#   Returns 1 when there is nothing to accept so the caller can fall back to
#   the stock forward-word widget.
_smart_display_accept_word() {
    local sug
    sug="$(_smart_state_get suggestion.text "")"
    [[ -z "$sug" ]] && return 1
    [[ "$sug" == "$BUFFER"* ]] || return 1

    local rest="${sug#$BUFFER}"
    [[ -z "$rest" ]] && return 1

    # Walk the tail character by character (no glob tricks, works on any zsh).
    local i ch word="" seen_nonspace=0
    for (( i = 1; i <= ${#rest}; i++ )); do
        ch="${rest[i]}"
        if [[ "$ch" == [[:space:]] ]]; then
            word+="$ch"
            # A separator AFTER real characters ends the word.
            (( seen_nonspace )) && break
        else
            word+="$ch"
            seen_nonspace=1
        fi
    done
    [[ -z "$word" ]] && return 1

    BUFFER="${BUFFER}${word}"
    CURSOR="${#BUFFER}"
    _smart_display_clear
    return 0
}
