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
#
# SMART_SUGGEST_COLOR=auto (the default) is resolved here so the choice can
# follow the terminal instead of being baked into the config file:
#
#   >= 256 colours  -> fg=110 (soft blue-grey)
#   otherwise       -> fg=8  (dim grey, the only value that fits a 16-colour
#                             terminal but renders almost like normal white
#                             text on some themes — the reason for the change)
#
# Any explicit value ("fg=8", "fg=cyan,bold", ...) short-circuits both branches,
# so nothing here can override the user.
# Split out so the policy is unit-testable: `terminfo` is a READ-ONLY special
# parameter, so the terminal-dependent part has to be reachable with explicit
# inputs rather than by poking the real one.
_smart_display_color_auto() {
    local term="${1:-$TERM}" ncolors="${2:-0}"
    (( ncolors >= 256 )) && { print -r -- "fg=110"; return 0; }
    # TERM is a second signal: several modern terminals either never publish a
    # colour count through terminfo (some SSH sessions) or use a naming scheme
    # terminfo does not enumerate. They are all colour-capable, so truecolor
    # names are treated exactly like *256color*.
    case "$term" in
        *256color*|*truecolor*|*24bit*|*-direct*|alacritty*|kitty*|foot*|wezterm*|gnome*|konsole*|vte*|iterm*)
            print -r -- "fg=110" ;;
        *)
            print -r -- "fg=8" ;;
    esac
}

_smart_display_color() {
    local c="${SMART_SUGGEST_COLOR}"
    [[ -z "$c" ]] && c="auto"
    if [[ "$c" == "auto" ]]; then
        c="$(_smart_display_color_auto "$TERM" "${terminfo[colors]:-0}")"
    fi
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
#
# NO EXPLICIT REDRAW HERE. This used to end with `zle -R "" ""`, "to force a
# redraw of the new region_highlight". It does the opposite of what it says:
# the redraw already happens, and the ARGUMENTS are what cost. Measured on the
# bytes zsh actually writes to a pty, one keystroke, two-line prompt:
#
#   with `zle -R "" ""`     96 bytes, including `\r\r\n '  ' ESC[A` and a
#                           full-line erase (ESC[K) on EVERY keystroke
#   without it              33 bytes: just the echo and the coloured ghost
#   both features OFF       with it 32 bytes, without it 1 byte — exactly what
#                           stock zsh writes for the same keystroke
#
# Only the SECOND argument does that (it is zsh's "more-specific display"
# prompt, and recomputing it forces a full prompt-area rebuild — see the table
# in _smart_menu_forget_rows, which is the one caller allowed to ask for it).
# The `\r\r\n` is a real newline. The prompt sits on the last row of the
# terminal most of the time — any command output leaves it there — and a
# newline on the last row scrolls the whole screen up by one row; the `ESC[A`
# that follows then lands on already-shifted content, which is what mixes the
# glyphs on the line being typed. So every key looked like it had been
# submitted, with a fresh prompt printed underneath: reported as "typing one
# character starts a new input line, without waiting for Enter".
# The array alone is enough: ZLE repaints once when the widget returns, and
# that repaint carries the ghost AND its colour (verified: the ghost still
# prints as `ESC[38;5;110m…` and still survives a candidate list being drawn).
_smart_display_update() {
    _smart_display_show
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
