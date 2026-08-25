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

# We mark our slot in region_highlight with a distinct comment string so we
# can remove only our own ranges without clobbering syntax-highlighter
# plugins (fast-syntax-highlighting, zsh-syntax-highlighting, etc.).
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

    local color
    color="$(_smart_display_color)"

    # 1. POSTDISPLAY carries the visual tail.
    POSTDISPLAY="$suffix"

    # 2. region_highlight colours the POSTDISPLAY region.
    #    POSTDISPLAY starts at offset ${#BUFFER} (0-based, end of BUFFER).
    local start="${#BUFFER}"
    local end=$(( start + ${#suffix} ))
    local new_entry="${start} ${end} ${color}  #${_SMART_RH_MARKER}"

    # Strip any prior entry of ours.
    local -a rh=("${region_highlight[@]}")
    local -a clean=()
    local r
    for r in "${rh[@]}"; do
        [[ "$r" == *"#${_SMART_RH_MARKER}"* ]] && continue
        clean+=("$r")
    done
    clean+=("$new_entry")
    region_highlight=("${clean[@]}")

    return 0
}

# _smart_display_clear -- undo _smart_display_show completely.
_smart_display_clear() {
    POSTDISPLAY=""
    PREDISPLAY=""
    if (( ${+region_highlight} )); then
        local -a rh=("${region_highlight[@]}")
        local -a clean=()
        local r
        for r in "${rh[@]}"; do
            [[ "$r" == *"#${_SMART_RH_MARKER}"* ]] && continue
            clean+=("$r")
        done
        region_highlight=("${clean[@]}")
    fi
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
