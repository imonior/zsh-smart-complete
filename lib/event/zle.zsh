# lib/event/zle.zsh
#
# ZLE event layer.
#
# THE RULE: No line-pre-redraw hook. No polling. Ever.
#
# Suggestions are computed ONLY when one of the following things happens:
#   - A character is typed             (self-insert variant)
#   - A character is deleted           (backward-delete-char variant)
#   - A word is killed                 (kill-word / backward-kill-word)
#   - Line is yanked                   (yank)
#   - Buffer is undone                 (undo)
#   - The user explicitly asks         (accept, tab, history up)
#
# This file:
#   1. Captures ORIGINAL widget bindings for the keys we wrap.
#   2. Registers our wrapper widgets with zle -N.
#   3. Exposes _smart_event_bind / _smart_event_unbind that
#      _smart_enable / _smart_disable call.
#   4. Wraps forward-char (→) so "at end of line + forward char" accepts
#      the current inline suggestion instead of silently beeping.
#
# All wrapper widgets follow a simple pattern:
#   a) Call the ORIGINAL widget so the user's existing behaviour never
#      regresses (self-insert inserts a char, etc.).
#   b) If the wrapper believes the BUFFER changed, run:
#          _smart_suggest_compute "$BUFFER"
#          _smart_display_update
#      Otherwise do nothing.
#
# Change detection (cheap, no hashing):
#   We keep state.buffer = the BUFFER we rendered a suggestion for last
#   time. We only re-run the engine if BUFFER != state.buffer. This means
#   cursor moves without edits (arrow keys) do NOT trigger a recompute.

emulate -L zsh
setopt extended_glob no_warn_create_global

# ---------------------------------------------------------------------------
# Saved originals (populated by _smart_event_capture_originals).
# Format: "widget-name" for bound, "" for unbound.
# ---------------------------------------------------------------------------
typeset -g _SMART_EVT_ORIG_SELF_EMACS=""
typeset -g _SMART_EVT_ORIG_SELF_VIINS=""
typeset -g _SMART_EVT_ORIG_BACKDEL_EMACS=""
typeset -g _SMART_EVT_ORIG_BACKDEL_VIINS=""
typeset -g _SMART_EVT_ORIG_DEL_EMACS=""
typeset -g _SMART_EVT_ORIG_DEL_VIINS=""
typeset -g _SMART_EVT_ORIG_FWDCHAR_EMACS=""
typeset -g _SMART_EVT_ORIG_FWDCHAR_VIINS=""
typeset -g _SMART_EVT_ORIG_KILLWORD_EMACS=""
typeset -g _SMART_EVT_ORIG_KILLWORD_VIINS=""
typeset -g _SMART_EVT_ORIG_BKWORDS_EMACS=""
typeset -g _SMART_EVT_ORIG_BKWORDS_VIINS=""
typeset -g _SMART_EVT_ORIG_YANK_EMACS=""
typeset -g _SMART_EVT_ORIG_YANK_VIINS=""
typeset -g _SMART_EVT_ORIG_UNDO_EMACS=""
typeset -g _SMART_EVT_ORIG_UNDO_VIINS=""
typeset -g _SMART_EVT_ORIG_HISTUP_VIINS=""
typeset -g _SMART_EVT_ORIG_HISTDOWN_VIINS=""
typeset -g _SMART_EVT_ORIG_FWDWORD_EMACS=""
typeset -g _SMART_EVT_ORIG_FWDWORD_VIINS=""

# ---------------------------------------------------------------------------
# Multi-sequence keys.
#
# A single logical key (→, ↑, Alt+→) has SEVERAL possible byte sequences, and
# which one your terminal actually sends depends on:
#   * $TERM's terminfo entry — for TERM=xterm-256color, kcuf1 (right arrow) is
#     "ESC O C", the *application cursor keys* form, NOT "ESC [ C";
#   * whether ZLE has put the terminal into that mode (it sends `smkx`).
#
# Binding only "ESC [ C" therefore leaves the right arrow dead on a plain
# xterm-256color session: the key arrives as "ESC O C", hits zsh's stock
# forward-char, and the suggestion is never accepted. We bind every form.
# ---------------------------------------------------------------------------
typeset -gaU _SMART_EVT_FWD_SEQS=()      # → accept whole suggestion
typeset -gaU _SMART_EVT_WORDFWD_SEQS=()  # Alt+→ accept one word
typeset -gaU _SMART_EVT_UP_SEQS=()
typeset -gaU _SMART_EVT_DOWN_SEQS=()

# Originals for the multi-sequence keys: "<keymap>|<seq>" -> widget name.
#
# zsh GOTCHA (cost us a silent regression): `assoc["a|b"]=x` stores the QUOTES
# as part of the key, so the entry becomes unreachable via `assoc[a|b]`. `|` is
# legal inside an unquoted subscript, so build the key in a variable and always
# index with an unquoted subscript — exactly like lib/state.zsh does.
typeset -gA _SMART_EVT_SAVED=()

_smart_evt_build_seq_lists() {
    # `terminfo` is a PARAMETER, so the module feature must be requested with
    # the `p:` prefix — `b:terminfo` is rejected ("no such feature") and would
    # leave the array undefined, silently losing the terminfo-derived arrows.
    zmodload -F zsh/terminfo p:terminfo 2>/dev/null
    local t _fwd
    _SMART_EVT_FWD_SEQS=()
    t="${terminfo[kcuf1]:-}"; [[ -n "$t" ]] && _SMART_EVT_FWD_SEQS+=("$t")
    _SMART_EVT_FWD_SEQS+=("^[[C" "^[OC")

    # Alt+→ : xterm-style "ESC [ 1 ; 3 C" plus the ESC-prefixed form of EVERY
    # plain right-arrow encoding above. Alt on a terminal is literally "send ESC
    # first, then the arrow", so it inherits the same multi-encoding problem as
    # → itself: macOS Terminal / application-cursor mode send "ESC ESC [ C" or
    # "ESC ESC O C", not "ESC [ 1 ; 3 C". Deriving from FWD_SEQS (instead of
    # hardcoding one form) is what stops Alt+→ from going dead on the exact
    # terminals where the plain arrow used to break.
    _SMART_EVT_WORDFWD_SEQS=()
    _SMART_EVT_WORDFWD_SEQS+=("^[[1;3C")
    for _fwd in "${_SMART_EVT_FWD_SEQS[@]}"; do
        _SMART_EVT_WORDFWD_SEQS+=("^[${_fwd}")
    done

    _SMART_EVT_UP_SEQS=()
    t="${terminfo[kcuu1]:-}"; [[ -n "$t" ]] && _SMART_EVT_UP_SEQS+=("$t")
    _SMART_EVT_UP_SEQS+=("^[[A" "^[OA")

    _SMART_EVT_DOWN_SEQS=()
    t="${terminfo[kcud1]:-}"; [[ -n "$t" ]] && _SMART_EVT_DOWN_SEQS+=("$t")
    _SMART_EVT_DOWN_SEQS+=("^[[B" "^[OB")
    return 0
}

# Sentinel: originals are captured exactly once per shell session. We use a
# DEDICATED flag instead of testing one ORIG_* variable, because a pre-set or
# stale value (e.g. a user manually exporting _SMART_EVT_ORIG_SELF_EMACS, or a
# re-source after an update) would otherwise skip the whole capture — silently
# losing the native Tab bindings and every other key's original too.
typeset -g _SMART_EVT_CAPTURED=0

# Helper reusing the binding probe from native.zsh.
_smart_evt_binding() {
    local km="$1" seq="$2"
    local out
    out=$(bindkey -M "$km" -- "$seq" 2>/dev/null) || { print -r -- ""; return 0; }
    # bindkey echoes `<key> <widget>`; the widget is ALWAYS the last field.
    #
    # Do NOT try to strip the key by matching $seq textually: bindkey always
    # prints the key in ^X caret notation, so for a sequence given as raw bytes
    # (e.g. the terminfo value $'\eOC') the match fails and the key text is
    # mistaken for the widget name. That silently poisons the saved originals
    # and the key is never restored on unbind.
    local w="${out##* }"
    # A range/seq with no single binding reports the pseudo-widget
    # "undefined-key" (e.g. `bindkey -M emacs "^@-^_"` → `"^@-^_" undefined-key`).
    # Treat it as UNBOUND so the caller's `[[ -z ]] && <default>` fallback
    # applies. Dispatching to `zle undefined-key` is a no-op that silently
    # swallows the keystroke — this is what broke typing printable ASCII.
    case "$w" in undefined-key|undefined) w="" ;; esac
    # Never accept one of OUR OWN widgets as an "original". If a capture ever
    # runs after we already bound a key, bindkey reports our wrapper — and
    # dispatching to it would recurse. Treat it as unbound so the caller's
    # built-in default is used instead.
    case "$w" in _smart_*|smart-*) w="" ;; esac
    print -r -- "$w"
}

_smart_event_capture_originals() {
    _SMART_EVT_ORIG_SELF_EMACS=$(_smart_evt_binding emacs "^@"-"^_" | head -n 1)
    # self-insert-command is implicitly bound for all printable chars; we
    # don't rebind individual printable keys. Instead we capture what
    # bindkey's "magic" range thinks the widget is (usually self-insert).
    # Most reliable: just hard-code self-insert for the default keymaps.
    [[ -z "$_SMART_EVT_ORIG_SELF_EMACS" ]] && _SMART_EVT_ORIG_SELF_EMACS="self-insert"
    _SMART_EVT_ORIG_SELF_VIINS="$_SMART_EVT_ORIG_SELF_EMACS"

    _SMART_EVT_ORIG_BACKDEL_EMACS=$(_smart_evt_binding emacs "^?")
    [[ -z "$_SMART_EVT_ORIG_BACKDEL_EMACS" ]] && _SMART_EVT_ORIG_BACKDEL_EMACS="backward-delete-char"
    _SMART_EVT_ORIG_BACKDEL_VIINS=$(_smart_evt_binding viins "^?")
    [[ -z "$_SMART_EVT_ORIG_BACKDEL_VIINS" ]] && _SMART_EVT_ORIG_BACKDEL_VIINS="backward-delete-char"
    _SMART_EVT_ORIG_DEL_EMACS=$(_smart_evt_binding emacs "^[[3~")
    [[ -z "$_SMART_EVT_ORIG_DEL_EMACS" ]] && _SMART_EVT_ORIG_DEL_EMACS="delete-char"
    _SMART_EVT_ORIG_DEL_VIINS=$(_smart_evt_binding viins "^[[3~")
    [[ -z "$_SMART_EVT_ORIG_DEL_VIINS" ]] && _SMART_EVT_ORIG_DEL_VIINS="delete-char"

    _SMART_EVT_ORIG_FWDCHAR_EMACS=$(_smart_evt_binding emacs "^[[C")
    [[ -z "$_SMART_EVT_ORIG_FWDCHAR_EMACS" ]] && _SMART_EVT_ORIG_FWDCHAR_EMACS="forward-char"
    _SMART_EVT_ORIG_FWDCHAR_VIINS=$(_smart_evt_binding viins "^[[C")
    [[ -z "$_SMART_EVT_ORIG_FWDCHAR_VIINS" ]] && _SMART_EVT_ORIG_FWDCHAR_VIINS="forward-char"

    _SMART_EVT_ORIG_KILLWORD_EMACS=$(_smart_evt_binding emacs "^[d")
    [[ -z "$_SMART_EVT_ORIG_KILLWORD_EMACS" ]] && _SMART_EVT_ORIG_KILLWORD_EMACS="kill-word"
    _SMART_EVT_ORIG_KILLWORD_VIINS=$(_smart_evt_binding viins "^[d")
    [[ -z "$_SMART_EVT_ORIG_KILLWORD_VIINS" ]] && _SMART_EVT_ORIG_KILLWORD_VIINS="kill-word"

    _SMART_EVT_ORIG_BKWORDS_EMACS=$(_smart_evt_binding emacs "^[^?")
    [[ -z "$_SMART_EVT_ORIG_BKWORDS_EMACS" ]] && _SMART_EVT_ORIG_BKWORDS_EMACS="backward-kill-word"
    _SMART_EVT_ORIG_BKWORDS_VIINS=$(_smart_evt_binding viins "^[^?")
    [[ -z "$_SMART_EVT_ORIG_BKWORDS_VIINS" ]] && _SMART_EVT_ORIG_BKWORDS_VIINS="backward-kill-word"

    _SMART_EVT_ORIG_YANK_EMACS=$(_smart_evt_binding emacs "^Y")
    [[ -z "$_SMART_EVT_ORIG_YANK_EMACS" ]] && _SMART_EVT_ORIG_YANK_EMACS="yank"
    _SMART_EVT_ORIG_YANK_VIINS=$(_smart_evt_binding viins "^Y")
    [[ -z "$_SMART_EVT_ORIG_YANK_VIINS" ]] && _SMART_EVT_ORIG_YANK_VIINS="yank"

    _SMART_EVT_ORIG_UNDO_EMACS=$(_smart_evt_binding emacs "^_")
    [[ -z "$_SMART_EVT_ORIG_UNDO_EMACS" ]] && _SMART_EVT_ORIG_UNDO_EMACS="undo"
    _SMART_EVT_ORIG_UNDO_VIINS=$(_smart_evt_binding viins "^_")
    [[ -z "$_SMART_EVT_ORIG_UNDO_VIINS" ]] && _SMART_EVT_ORIG_UNDO_VIINS="undo"

    _SMART_EVT_ORIG_HISTUP_VIINS=$(_smart_evt_binding viins "^[[A")
    [[ -z "$_SMART_EVT_ORIG_HISTUP_VIINS" ]] && _SMART_EVT_ORIG_HISTUP_VIINS="up-line-or-history"
    _SMART_EVT_ORIG_HISTDOWN_VIINS=$(_smart_evt_binding viins "^[[B")
    [[ -z "$_SMART_EVT_ORIG_HISTDOWN_VIINS" ]] && _SMART_EVT_ORIG_HISTDOWN_VIINS="down-line-or-history"

    # Alt+→ (accept one word). Same probe, per keymap.
    _SMART_EVT_ORIG_FWDWORD_EMACS=$(_smart_evt_binding emacs "^[[1;3C")
    [[ -z "$_SMART_EVT_ORIG_FWDWORD_EMACS" ]] && _SMART_EVT_ORIG_FWDWORD_EMACS="forward-word"
    _SMART_EVT_ORIG_FWDWORD_VIINS=$(_smart_evt_binding viins "^[[1;3C")
    [[ -z "$_SMART_EVT_ORIG_FWDWORD_VIINS" ]] && _SMART_EVT_ORIG_FWDWORD_VIINS="forward-word"

    # Every extra byte sequence for the arrows / Alt+→ gets its own original.
    _smart_evt_build_seq_lists
    local km2 seq seqkey
    for km2 in emacs viins; do
        for seq in "${_SMART_EVT_FWD_SEQS[@]}" "${_SMART_EVT_WORDFWD_SEQS[@]}" \
                   "${_SMART_EVT_UP_SEQS[@]}" "${_SMART_EVT_DOWN_SEQS[@]}"; do
            [[ -z "$seq" ]] && continue
            seqkey="${km2}|${seq}"
            _SMART_EVT_SAVED[$seqkey]="$(_smart_evt_binding "$km2" "$seq")"
        done
    done

    # Also save originals in the native-completion module (Tab).
    if (( ${+functions[_smart_native_save_original_bindings]} )); then
        _smart_native_save_original_bindings
    fi
    _SMART_EVT_CAPTURED=1
    return 0
}

# _smart_evt_dispatch <scalar_var> <fallback_default>
# Call the widget named by the scalar; fallback if it is unset/missing.
_smart_evt_dispatch() {
    local widget="$1" fallback="$2"
    # Never dispatch to the no-op pseudo-widget: guard against a bad capture
    # leaving "undefined-key" (or empty) so printable input is never dropped.
    case "$widget" in ""|undefined-key|undefined) widget="$fallback" ;; esac
    if (( ${+widgets[$widget]} )); then
        zle "$widget"
    else
        zle "$fallback"
    fi
}

# ---------------------------------------------------------------------------
# Core re-computation driver
# ---------------------------------------------------------------------------

# _smart_evt_after_edit
# Call AFTER calling the original widget that may have modified BUFFER.
# Recomputes suggestion + display ONLY if BUFFER actually differs from the
# last one we rendered for.
_smart_evt_after_edit() {
    # Runtime disabled? Still clear display so no stale ghost remains.
    if (( ${_SMART_STATE[enabled]:-1} == 0 )); then
        (( ${+functions[_smart_display_clear]} )) && _smart_display_clear
        return 0
    fi

    local last_buf
    last_buf="$(_smart_state_get buffer "")"

    if [[ "$BUFFER" != "$last_buf" ]]; then
        # Buffer actually changed → compute + render.
        _smart_suggest_compute "$BUFFER"
        # SMART_SUGGEST_STRATEGY may allow the completion system as a fallback
        # source when history had nothing. Runs BEFORE we record the buffer,
        # because the probe temporarily edits and restores $BUFFER.
        _smart_evt_completion_fallback
        _smart_state_set buffer "$BUFFER"
        _smart_display_update 2>/dev/null
    elif [[ -n "$POSTDISPLAY" ]]; then
        # Same buffer but POSTDISPLAY may be stale. Keep current suggestion
        # (it's still valid) but re-render in case cursor moved off the end.
        _smart_display_show 2>/dev/null
    fi
    return 0
}

# _smart_evt_completion_fallback
#
# zsh-autosuggestions' `strategy=completion`, reimplemented on our side: when
# history produced nothing and the configured strategy allows it, ask the
# completion system for the unambiguous prefix of the word under the cursor and
# offer THAT as the ghost. This is what lets the suggestion channel cover paths,
# options and subcommands that were never in the history file.
#
# Cost control: it only runs when history came up empty, so an ordinary session
# (history usually answers) pays nothing.
_smart_evt_completion_fallback() {
    [[ -n "$(_smart_state_get suggestion.text "")" ]] && return 0
    _smart_suggest_strategy_has completion || return 0
    (( ${+functions[_smart_menu_completion_suffix]} )) || return 0

    local suffix
    suffix="$(_smart_menu_completion_suffix)"
    [[ -n "$suffix" ]] || return 0

    _smart_state_set suggestion.text  "${BUFFER}${suffix}"
    _smart_state_set suggestion.source "completion"
    _smart_state_set suggestion.score  ""
    return 0
}

# _smart_evt_after_edit_all -- for the pure-EDIT widgets: recompute the
# suggestion AND refresh the candidate menu. History navigation deliberately
# skips the menu half (recalling a line should not dump a candidate list).
_smart_evt_after_edit_all() {
    _smart_evt_after_edit
    if (( ${+functions[_smart_menu_tick]} )); then
        _smart_menu_tick 2>/dev/null
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Widgets (all registered via zle -N below)
# ---------------------------------------------------------------------------

_smart_widget_self_insert() {
    local km="${KEYMAP:-emacs}"
    case "$km" in
        viins|main) _smart_evt_dispatch "$_SMART_EVT_ORIG_SELF_VIINS"   self-insert ;;
        *)          _smart_evt_dispatch "$_SMART_EVT_ORIG_SELF_EMACS"   self-insert ;;
    esac
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_evt_after_edit_all
}
zle -N _smart_widget_self_insert 2>/dev/null

_smart_widget_backward_delete_char() {
    local km="${KEYMAP:-emacs}"
    case "$km" in
        viins|main) _smart_evt_dispatch "$_SMART_EVT_ORIG_BACKDEL_VIINS" backward-delete-char ;;
        *)          _smart_evt_dispatch "$_SMART_EVT_ORIG_BACKDEL_EMACS" backward-delete-char ;;
    esac
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_evt_after_edit_all
}
zle -N _smart_widget_backward_delete_char 2>/dev/null
_smart_widget_delete_char() {
    local km="${KEYMAP:-emacs}"
    case "$km" in
        viins|main) _smart_evt_dispatch "$_SMART_EVT_ORIG_DEL_VIINS" delete-char ;;
        *)          _smart_evt_dispatch "$_SMART_EVT_ORIG_DEL_EMACS" delete-char ;;
    esac
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_evt_after_edit_all
}
zle -N _smart_widget_delete_char 2>/dev/null

_smart_widget_forward_char() {
    # → key. If:
    #   a) we are at END of line (CURSOR == ${#BUFFER})
    #   b) there IS a current suggestion that extends BUFFER
    # Then accept suggestion; otherwise original forward-char.
    local sug
    sug="$(_smart_state_get suggestion.text "")"
    if (( CURSOR == ${#BUFFER} )) && [[ -n "$sug" ]] && [[ "$sug" == "$BUFFER"* ]]; then
        _smart_display_accept_partial
        (( ${+functions[_smart_menu_clear]} )) && _smart_menu_clear
        # The list left over from the last keystroke belongs to the old prefix.
        zle -R "" "" 2>/dev/null
        return 0
    fi
    local km="${KEYMAP:-emacs}"
    case "$km" in
        viins|main) _smart_evt_dispatch "$_SMART_EVT_ORIG_FWDCHAR_VIINS" forward-char ;;
        *)          _smart_evt_dispatch "$_SMART_EVT_ORIG_FWDCHAR_EMACS" forward-char ;;
    esac
}
zle -N _smart_widget_forward_char 2>/dev/null

# Alt+→ : accept ONE word of the inline suggestion, then keep suggesting the
# rest. With no suggestion (or cursor not at end) it degrades to the original
# forward-word, so the key never becomes a dead key.
_smart_widget_accept_word() {
    local sug
    sug="$(_smart_state_get suggestion.text "")"
    if (( CURSOR == ${#BUFFER} )) && [[ -n "$sug" ]] && \
       [[ "$sug" == "$BUFFER"* ]] && [[ "$sug" != "$BUFFER" ]]; then
        _smart_display_accept_word 2>/dev/null
        (( ${+functions[_smart_menu_clear]} )) && _smart_menu_clear
        # Force a recompute so the ghost shrinks to the remaining tail and the
        # candidate list reflects the new prefix.
        _smart_state_set buffer ""
        _smart_evt_after_edit_all
        return 0
    fi
    local km="${KEYMAP:-emacs}"
    case "$km" in
        viins|main) _smart_evt_dispatch "$_SMART_EVT_ORIG_FWDWORD_VIINS" forward-word ;;
        *)          _smart_evt_dispatch "$_SMART_EVT_ORIG_FWDWORD_EMACS" forward-word ;;
    esac
}
zle -N _smart_widget_accept_word 2>/dev/null

# ---------------------------------------------------------------------------
# Public, user-bindable widget names (parity with zsh-autosuggestions)
#
# zsh-autosuggestions exposes named widgets so users can rebind them
# (`bindkey '^ ' autosuggest-accept`, etc.). These are the equivalents, so the
# same recipes work after swapping the plugin:
#
#   smart-accept-suggestion   accept the whole suggestion (else forward-char)
#   smart-accept-word         accept one word of the suggestion
#   smart-execute-suggestion  accept the whole suggestion, then run the line
#   smart-suggestion-toggle   turn the inline ghost on/off at runtime
#
# They are deliberately thin wrappers: all logic stays in one place, so a fix
# can never apply to the default binding but not to a user's rebinding.
# ---------------------------------------------------------------------------

smart-accept-suggestion() { _smart_widget_forward_char }
zle -N smart-accept-suggestion 2>/dev/null

smart-accept-word() { _smart_widget_accept_word }
zle -N smart-accept-word 2>/dev/null

# Accept the suggestion and execute, in one keystroke — the "just do what I
# meant" binding some people put on a spare key.
smart-execute-suggestion() {
    local sug
    sug="$(_smart_state_get suggestion.text "")"
    if (( CURSOR == ${#BUFFER} )) && [[ -n "$sug" ]] && [[ "$sug" == "$BUFFER"* ]]; then
        _smart_display_accept_partial
        (( ${+functions[_smart_menu_clear]} )) && _smart_menu_clear
    fi
    _smart_widget_accept_line
}
zle -N smart-execute-suggestion 2>/dev/null

# Toggle the inline ghost without touching the candidate menu (the menu has its
# own switch: `smart-menu off`). Useful when a suggestion is in the way.
smart-suggestion-toggle() {
    case "${SMART_INLINE}" in
        false|no|off|0|disabled)
            SMART_INLINE=true
            print -r -- "smart-suggestion: on"
            ;;
        *)
            SMART_INLINE=false
            _smart_display_clear 2>/dev/null
            print -r -- "smart-suggestion: off"
            ;;
    esac
    zle reset-prompt 2>/dev/null
    return 0
}
zle -N smart-suggestion-toggle 2>/dev/null

_smart_widget_kill_word() {
    local km="${KEYMAP:-emacs}"
    case "$km" in
        viins|main) _smart_evt_dispatch "$_SMART_EVT_ORIG_KILLWORD_VIINS" kill-word ;;
        *)          _smart_evt_dispatch "$_SMART_EVT_ORIG_KILLWORD_EMACS" kill-word ;;
    esac
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_evt_after_edit_all
}
zle -N _smart_widget_kill_word 2>/dev/null

_smart_widget_backward_kill_word() {
    local km="${KEYMAP:-emacs}"
    case "$km" in
        viins|main) _smart_evt_dispatch "$_SMART_EVT_ORIG_BKWORDS_VIINS" backward-kill-word ;;
        *)          _smart_evt_dispatch "$_SMART_EVT_ORIG_BKWORDS_EMACS" backward-kill-word ;;
    esac
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_evt_after_edit_all
}
zle -N _smart_widget_backward_kill_word 2>/dev/null

_smart_widget_yank() {
    local km="${KEYMAP:-emacs}"
    case "$km" in
        viins|main) _smart_evt_dispatch "$_SMART_EVT_ORIG_YANK_VIINS" yank ;;
        *)          _smart_evt_dispatch "$_SMART_EVT_ORIG_YANK_EMACS" yank ;;
    esac
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_evt_after_edit_all
}
zle -N _smart_widget_yank 2>/dev/null

_smart_widget_undo() {
    local km="${KEYMAP:-emacs}"
    case "$km" in
        viins|main) _smart_evt_dispatch "$_SMART_EVT_ORIG_UNDO_VIINS" undo ;;
        *)          _smart_evt_dispatch "$_SMART_EVT_ORIG_UNDO_EMACS" undo ;;
    esac
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_evt_after_edit_all
}
zle -N _smart_widget_undo 2>/dev/null

# History navigation: strictly native, reset completion state.
_smart_widget_history_up() {
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_display_clear 2>/dev/null
    _smart_evt_dispatch "$_SMART_EVT_ORIG_HISTUP_VIINS" up-line-or-history
    _smart_evt_after_edit
}
zle -N _smart_widget_history_up 2>/dev/null

_smart_widget_history_down() {
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_display_clear 2>/dev/null
    _smart_evt_dispatch "$_SMART_EVT_ORIG_HISTDOWN_VIINS" down-line-or-history
    _smart_evt_after_edit
}
zle -N _smart_widget_history_down 2>/dev/null

# ---------------------------------------------------------------------------
# ↑ / ↓ prefix history search (zsh-autocomplete's headline behaviour).
#
# Opt-in via SMART_MENU_HISTORY_KEYS=true, because it takes over a key most
# people have deep muscle memory for. What it does:
#
#   line non-empty -> ↑ / ↓ walk the history entries that START WITH the line
#                     you have typed, using zsh's own
#                     history-beginning-search-backward / -forward. So typing
#                     `git ch` then ↑ recalls your last `git checkout ...`.
#   line empty     -> falls straight through to plain history navigation, so
#                     you can always still scroll the history.
#
# It is built on stock ZLE widgets (not a reimplementation): the search is
# zsh's, we only add the "which of the two behaviours" rule and keep the ghost
# and the candidate menu in sync afterwards.
# ---------------------------------------------------------------------------

_smart_widget_history_prefix_up() {
    if [[ -z "$BUFFER" ]] || ! _smart_menu_enabled 2>/dev/null; then
        _smart_widget_history_up
        return 0
    fi
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_display_clear 2>/dev/null
    if (( ${+widgets[.history-beginning-search-backward]} )); then
        zle .history-beginning-search-backward
    else
        zle .up-line-or-history
    fi
    # The recalled line is a new buffer as far as the engines are concerned.
    _smart_state_set buffer ""
    _smart_evt_after_edit_all
    return 0
}
zle -N _smart_widget_history_prefix_up 2>/dev/null

_smart_widget_history_prefix_down() {
    if [[ -z "$BUFFER" ]] || ! _smart_menu_enabled 2>/dev/null; then
        _smart_widget_history_down
        return 0
    fi
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_display_clear 2>/dev/null
    if (( ${+widgets[.history-beginning-search-forward]} )); then
        zle .history-beginning-search-forward
    else
        zle .down-line-or-history
    fi
    _smart_state_set buffer ""
    _smart_evt_after_edit_all
    return 0
}
zle -N _smart_widget_history_prefix_down 2>/dev/null

# The "accept-line" widget (Enter).
#
# ALWAYS executes the line. An open completion menu does NOT change what Enter
# means, and this used to be treated as "accept the selection but do not run":
# any Tab press set _SMART_COMPLETION_ACTIVE, so the very next Enter was
# swallowed — the command sat there unchanged until you pressed Enter a second
# time. Measured on released v2.2.1 as well, so it is a long-standing bug, not a
# regression. Nothing is lost by executing: our Tab bridge uses `menu-complete`,
# which inserts a candidate outright (zsh's own menu-select likewise inserts the
# selection and accepts in one keystroke), so there is no pending choice to defer
# to.
#
# What we still do here is tidy up: the completion-state flag and the ghost text
# must never leak into the next line.
_smart_widget_accept_line() {
    _smart_native_reset_completion 2>/dev/null
    _smart_display_clear 2>/dev/null

    # Make sure the history-on-new-command hook is registered exactly once.
    if (( ${+preexec_functions} )); then
        local already=0 f
        for f in "${preexec_functions[@]}"; do
            [[ "$f" == "_smart_history_on_new_command" ]] && already=1
        done
        (( already == 0 )) && preexec_functions+=(_smart_history_on_new_command)
    fi
    zle .accept-line
}
zle -N _smart_widget_accept_line 2>/dev/null

# ---------------------------------------------------------------------------
# Bind / unbind (called by smart-enable / smart-disable)
# ---------------------------------------------------------------------------

# _smart_event_bind -- install our wrappers into active keymaps.
_smart_event_bind() {
    # Capture originals exactly once per shell session (they don't change).
    # Test the dedicated flag, NOT the content of an ORIG_* variable: a
    # pre-set/stale value must never skip the capture, because that would also
    # skip the native Tab bindings and every other key's original.
    if (( ${_SMART_EVT_CAPTURED:-0} != 1 )); then
        _smart_event_capture_originals
    fi

    local scope="${SMART_KEYMAP_SCOPE:-both}"

    # The sequence lists are built during original-capture; rebuild defensively
    # so a hand-set capture flag can never leave them empty.
    (( ${#_SMART_EVT_FWD_SEQS} )) || _smart_evt_build_seq_lists

    # Determine which keymaps to touch.
    local -a kms=()
    case "$scope" in
        both)   kms=(emacs viins) ;;
        emacs)  kms=(emacs) ;;
        viins)  kms=(viins) ;;
        *)      kms=(emacs viins) ;;
    esac

    # NOTE: every loop variable is declared HERE, once. Declaring a local
    # inside a loop that runs more than once makes zsh 5.9 print the variable's
    # previous value to stdout on the second iteration — which in a ZLE widget
    # path scribbles straight over the command line.
    local km km2 km3 _s _k _seq _orig _kmname
    for km in "${kms[@]}"; do
        # self-insert (all printable chars) — zsh provides the handy
        # "bindkey -R $from-$to" range syntax.
        # Note: viins also uses self-insert for printables.
        bindkey -M "$km" -R "^@"-"^_" _smart_widget_self_insert 2>/dev/null
        bindkey -M "$km" -R " "-"~"  _smart_widget_self_insert 2>/dev/null

        # Backspace (^? = 127)
        bindkey -M "$km" "^?" _smart_widget_backward_delete_char 2>/dev/null
        # Delete (^[[3~ = ESC [ 3 ~ = forward delete)
        bindkey -M "$km" "^[[3~" _smart_widget_delete_char 2>/dev/null

        # → (every encoding the terminal may use: CSI and SS3/application
        # cursor keys). Accepts the inline suggestion at end of line.
        for _s in "${_SMART_EVT_FWD_SEQS[@]}"; do
            [[ -z "$_s" ]] && continue
            bindkey -M "$km" "$_s" _smart_widget_forward_char 2>/dev/null
        done
        # Alt+→ accepts ONE word of the suggestion (then re-suggests the rest).
        for _s in "${_SMART_EVT_WORDFWD_SEQS[@]}"; do
            [[ -z "$_s" ]] && continue
            bindkey -M "$km" "$_s" _smart_widget_accept_word 2>/dev/null
        done

        # Alt+d = kill-word
        bindkey -M "$km" "^[d"  _smart_widget_kill_word 2>/dev/null
        # Alt+Backspace = backward-kill-word (^[^? = ESC + 127)
        bindkey -M "$km" "^[^?" _smart_widget_backward_kill_word 2>/dev/null

        # ^Y = yank
        bindkey -M "$km" "^Y"   _smart_widget_yank 2>/dev/null

        # ^_ = undo
        bindkey -M "$km" "^_"   _smart_widget_undo 2>/dev/null

        # Enter = accept-line (clear display on accept)
        bindkey -M "$km" "^M"   _smart_widget_accept_line 2>/dev/null
    done

    # History arrows.
    #
    # Default (SMART_MENU_HISTORY_KEYS=false): only viins is wrapped, purely to
    # reset completion/ghost state — emacs arrows keep their stock
    # up-line-or-history so nothing about them changes.
    #
    # SMART_MENU_HISTORY_KEYS=true: ↑/↓ become prefix history search in EVERY
    # keymap in scope (that is the whole point of the option). The wrapper still
    # degrades to plain history navigation on an empty line, so nothing is lost.
    if [[ "${SMART_MENU_HISTORY_KEYS:-false}" == "true" ]]; then
        for km2 in "${kms[@]}"; do
            for _s in "${_SMART_EVT_UP_SEQS[@]}"; do
                [[ -z "$_s" ]] && continue
                bindkey -M "$km2" "$_s" _smart_widget_history_prefix_up 2>/dev/null
            done
            for _s in "${_SMART_EVT_DOWN_SEQS[@]}"; do
                [[ -z "$_s" ]] && continue
                bindkey -M "$km2" "$_s" _smart_widget_history_prefix_down 2>/dev/null
            done
        done
    elif (( ${#kms[(r)viins]} > 0 )); then
        for _s in "${_SMART_EVT_UP_SEQS[@]}"; do
            [[ -z "$_s" ]] && continue
            bindkey -M viins "$_s" _smart_widget_history_up 2>/dev/null
        done
        for _s in "${_SMART_EVT_DOWN_SEQS[@]}"; do
            [[ -z "$_s" ]] && continue
            bindkey -M viins "$_s" _smart_widget_history_down 2>/dev/null
        done
    fi

    # Tab — handled by the native completion bridge (first Tab = complete,
    # subsequent = menu-complete cycle).
    for km2 in "${kms[@]}"; do
        bindkey -M "$km2" "^I" _smart_native_complete 2>/dev/null
        # Shift+Tab = reverse-menu-complete (cycle to previous candidate).
        bindkey -M "$km2" "^[[Z" _smart_native_reverse_complete 2>/dev/null
    done
    # vicmd Tab too if the keymap scope allows it.
    case "$scope" in
        both|*)
            bindkey -M vicmd "^I" _smart_native_complete 2>/dev/null 2>/dev/null
            bindkey -M vicmd "^[[Z" _smart_native_reverse_complete 2>/dev/null 2>/dev/null
            ;;
    esac

    # Ctrl+G = toggle enable/disable.
    for km in "${kms[@]}"; do
        bindkey -M "$km" "^G" smart-toggle 2>/dev/null
    done

    return 0
}

# _smart_event_unbind -- restore original bindings 1:1.
_smart_event_unbind() {
    local scope="${SMART_KEYMAP_SCOPE:-both}"
    local -a kms=()
    case "$scope" in
        both)   kms=(emacs viins) ;;
        emacs)  kms=(emacs) ;;
        viins)  kms=(viins) ;;
        *)      kms=(emacs viins) ;;
    esac

    local km w km2 km3 _s _k _seq _orig _kmname
    for km in "${kms[@]}"; do
        case "$km" in
            emacs)  w="$_SMART_EVT_ORIG_SELF_EMACS" ;;
            viins)  w="$_SMART_EVT_ORIG_SELF_VIINS" ;;
        esac
        [[ -z "$w" ]] && w="self-insert"
        bindkey -M "$km" -R "^@"-"^_" "$w" 2>/dev/null
        bindkey -M "$km" -R " "-"~"  "$w" 2>/dev/null

        case "$km" in
            emacs)  w="$_SMART_EVT_ORIG_BACKDEL_EMACS" ;;
            viins)  w="$_SMART_EVT_ORIG_BACKDEL_VIINS" ;;
        esac
        [[ -n "$w" ]] && bindkey -M "$km" "^?" "$w" 2>/dev/null || bindkey -M "$km" "^?" backward-delete-char 2>/dev/null
        case "$km" in
            emacs)  w="$_SMART_EVT_ORIG_DEL_EMACS" ;;
            viins)  w="$_SMART_EVT_ORIG_DEL_VIINS" ;;
        esac
        [[ -n "$w" ]] && bindkey -M "$km" "^[[3~" "$w" 2>/dev/null || bindkey -M "$km" "^[[3~" delete-char 2>/dev/null

        case "$km" in
            emacs)  w="$_SMART_EVT_ORIG_FWDCHAR_EMACS" ;;
            viins)  w="$_SMART_EVT_ORIG_FWDCHAR_VIINS" ;;
        esac
        [[ -n "$w" ]] && bindkey -M "$km" "^[[C" "$w" 2>/dev/null || bindkey -M "$km" "^[[C" forward-char 2>/dev/null

        case "$km" in
            emacs)  w="$_SMART_EVT_ORIG_KILLWORD_EMACS" ;;
            viins)  w="$_SMART_EVT_ORIG_KILLWORD_VIINS" ;;
        esac
        [[ -n "$w" ]] && bindkey -M "$km" "^[d" "$w" 2>/dev/null || bindkey -M "$km" "^[d" kill-word 2>/dev/null

        case "$km" in
            emacs)  w="$_SMART_EVT_ORIG_BKWORDS_EMACS" ;;
            viins)  w="$_SMART_EVT_ORIG_BKWORDS_VIINS" ;;
        esac
        [[ -n "$w" ]] && bindkey -M "$km" "^[^?" "$w" 2>/dev/null || bindkey -M "$km" "^[^?" backward-kill-word 2>/dev/null

        case "$km" in
            emacs)  w="$_SMART_EVT_ORIG_YANK_EMACS" ;;
            viins)  w="$_SMART_EVT_ORIG_YANK_VIINS" ;;
        esac
        [[ -n "$w" ]] && bindkey -M "$km" "^Y" "$w" 2>/dev/null || bindkey -M "$km" "^Y" yank 2>/dev/null

        case "$km" in
            emacs)  w="$_SMART_EVT_ORIG_UNDO_EMACS" ;;
            viins)  w="$_SMART_EVT_ORIG_UNDO_VIINS" ;;
        esac
        [[ -n "$w" ]] && bindkey -M "$km" "^_" "$w" 2>/dev/null || bindkey -M "$km" "^_" undo 2>/dev/null

        # Enter: .accept-line is always the builtin.
        bindkey -M "$km" "^M" .accept-line 2>/dev/null

        # Ctrl+G: unbind.
        bindkey -M "$km" -r "^G" 2>/dev/null
    done

    # viins history arrows.
    w="$_SMART_EVT_ORIG_HISTUP_VIINS"
    [[ -n "$w" ]] && bindkey -M viins "^[[A" "$w" 2>/dev/null || bindkey -M viins "^[[A" up-line-or-history 2>/dev/null
    w="$_SMART_EVT_ORIG_HISTDOWN_VIINS"
    [[ -n "$w" ]] && bindkey -M viins "^[[B" "$w" 2>/dev/null || bindkey -M viins "^[[B" down-line-or-history 2>/dev/null

    # Every extra arrow / Alt+→ sequence: put back exactly what we found.
    for _k in "${(@k)_SMART_EVT_SAVED}"; do
        _kmname="${_k%%|*}"
        _seq="${_k#*|}"
        _orig="${_SMART_EVT_SAVED[$_k]}"
        case "$_kmname" in emacs|viins) ;; *) continue ;; esac
        if [[ -n "$_orig" ]]; then
            bindkey -M "$_kmname" "$_seq" "$_orig" 2>/dev/null
        else
            bindkey -M "$_kmname" -r "$_seq" 2>/dev/null
        fi
    done

    # Tab + Shift+Tab (native bridge) → restore originals captured in native.zsh.
    if (( ${+functions[_smart_native_restore_original_bindings]} )); then
        _smart_native_restore_original_bindings
    fi
    # Unbind Shift+Tab (we own it; there's no "original" to restore).
    for km3 in "${kms[@]}"; do
        bindkey -M "$km3" -r "^[[Z" 2>/dev/null
    done
    bindkey -M vicmd -r "^[[Z" 2>/dev/null

    return 0
}
