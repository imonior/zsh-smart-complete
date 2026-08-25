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

# Helper reusing the binding probe from native.zsh.
_smart_evt_binding() {
    local km="$1" seq="$2"
    local out
    out=$(bindkey -M "$km" -- "$seq" 2>/dev/null) || { print -r -- ""; return 0; }
    local rest="${out#*\"${seq}\" }"
    if [[ "$rest" == "$out" ]]; then
        rest="${out#${seq} }"
    fi
    print -r -- "${rest%% *}"
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

    # Also save originals in the native-completion module (Tab).
    if (( ${+functions[_smart_native_save_original_bindings]} )); then
        _smart_native_save_original_bindings
    fi
    return 0
}

# _smart_evt_dispatch <scalar_var> <fallback_default>
# Call the widget named by the scalar; fallback if it is unset/missing.
_smart_evt_dispatch() {
    local widget="$1" fallback="$2"
    [[ -z "$widget" ]] && widget="$fallback"
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
    if (( $(_smart_state_get enabled 1) == 0 )); then
        (( ${+functions[_smart_display_clear]} )) && _smart_display_clear
        return 0
    fi

    local last_buf
    last_buf="$(_smart_state_get buffer "")"

    if [[ "$BUFFER" != "$last_buf" ]]; then
        # Buffer actually changed → compute + render.
        _smart_suggest_compute "$BUFFER"
        _smart_state_set buffer "$BUFFER"
        _smart_display_update 2>/dev/null
    elif [[ -n "$POSTDISPLAY" ]]; then
        # Same buffer but POSTDISPLAY may be stale. Keep current suggestion
        # (it's still valid) but re-render in case cursor moved off the end.
        _smart_display_show 2>/dev/null
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
    _smart_evt_after_edit
}
zle -N _smart_widget_self_insert 2>/dev/null

_smart_widget_backward_delete_char() {
    local km="${KEYMAP:-emacs}"
    case "$km" in
        viins|main) _smart_evt_dispatch "$_SMART_EVT_ORIG_BACKDEL_VIINS" backward-delete-char ;;
        *)          _smart_evt_dispatch "$_SMART_EVT_ORIG_BACKDEL_EMACS" backward-delete-char ;;
    esac
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_evt_after_edit
}
zle -N _smart_widget_backward_delete_char 2>/dev/null

_smart_widget_forward_char() {
    # → key. If:
    #   a) we are at END of line (CURSOR == ${#BUFFER})
    #   b) there IS a current suggestion that extends BUFFER
    # Then accept suggestion; otherwise original forward-char.
    local sug
    sug="$(_smart_state_get suggestion.text "")"
    if (( CURSOR == ${#BUFFER} )) && [[ -n "$sug" ]] && [[ "$sug" == "$BUFFER"* ]]; then
        _smart_display_accept_partial
        return $?
    fi
    local km="${KEYMAP:-emacs}"
    case "$km" in
        viins|main) _smart_evt_dispatch "$_SMART_EVT_ORIG_FWDCHAR_VIINS" forward-char ;;
        *)          _smart_evt_dispatch "$_SMART_EVT_ORIG_FWDCHAR_EMACS" forward-char ;;
    esac
}
zle -N _smart_widget_forward_char 2>/dev/null

_smart_widget_kill_word() {
    local km="${KEYMAP:-emacs}"
    case "$km" in
        viins|main) _smart_evt_dispatch "$_SMART_EVT_ORIG_KILLWORD_VIINS" kill-word ;;
        *)          _smart_evt_dispatch "$_SMART_EVT_ORIG_KILLWORD_EMACS" kill-word ;;
    esac
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_evt_after_edit
}
zle -N _smart_widget_kill_word 2>/dev/null

_smart_widget_backward_kill_word() {
    local km="${KEYMAP:-emacs}"
    case "$km" in
        viins|main) _smart_evt_dispatch "$_SMART_EVT_ORIG_BKWORDS_VIINS" backward-kill-word ;;
        *)          _smart_evt_dispatch "$_SMART_EVT_ORIG_BKWORDS_EMACS" backward-kill-word ;;
    esac
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_evt_after_edit
}
zle -N _smart_widget_backward_kill_word 2>/dev/null

_smart_widget_yank() {
    local km="${KEYMAP:-emacs}"
    case "$km" in
        viins|main) _smart_evt_dispatch "$_SMART_EVT_ORIG_YANK_VIINS" yank ;;
        *)          _smart_evt_dispatch "$_SMART_EVT_ORIG_YANK_EMACS" yank ;;
    esac
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_evt_after_edit
}
zle -N _smart_widget_yank 2>/dev/null

_smart_widget_undo() {
    local km="${KEYMAP:-emacs}"
    case "$km" in
        viins|main) _smart_evt_dispatch "$_SMART_EVT_ORIG_UNDO_VIINS" undo ;;
        *)          _smart_evt_dispatch "$_SMART_EVT_ORIG_UNDO_EMACS" undo ;;
    esac
    (( ${+functions[_smart_native_reset_completion]} )) && _smart_native_reset_completion 2>/dev/null
    _smart_evt_after_edit
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

# The "accept-line" widget.
# If completion menu is active: accept current selection, DON'T execute.
# Otherwise: clear display, schedule index bump, execute the line.
_smart_widget_accept_line() {
    # Completion active → accept selection but don't execute.
    if (( ${+_SMART_COMPLETION_ACTIVE} )) && (( _SMART_COMPLETION_ACTIVE == 1 )); then
        _smart_native_reset_completion 2>/dev/null
        _smart_display_clear 2>/dev/null
        # Leave the completed word in BUFFER; user can continue editing.
        zle redisplay 2>/dev/null
        return 0
    fi

    # Normal execute path.
    _smart_display_clear 2>/dev/null
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
    if [[ -z "$_SMART_EVT_ORIG_SELF_EMACS" ]]; then
        _smart_event_capture_originals
    fi

    local scope="${SMART_KEYMAP_SCOPE:-both}"

    # Determine which keymaps to touch.
    local -a kms=()
    case "$scope" in
        both)   kms=(emacs viins) ;;
        emacs)  kms=(emacs) ;;
        viins)  kms=(viins) ;;
        *)      kms=(emacs viins) ;;
    esac

    local km
    for km in "${kms[@]}"; do
        # self-insert (all printable chars) — zsh provides the handy
        # "bindkey -R $from-$to" range syntax.
        # Note: viins also uses self-insert for printables.
        bindkey -M "$km" -R "^@"-"^_" _smart_widget_self_insert 2>/dev/null
        bindkey -M "$km" -R " "-"~"  _smart_widget_self_insert 2>/dev/null

        # Backspace (^? = 127)
        bindkey -M "$km" "^?" _smart_widget_backward_delete_char 2>/dev/null

        # → (ESC [ C)
        bindkey -M "$km" "^[[C" _smart_widget_forward_char 2>/dev/null
        # Also bind ^[f (Alt+F = forward-word) just in case user prefers it;
        # we still run the original forward-char widget (the user had ^[[C
        # bound to that anyway) so no loss.

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

    # History arrows only in viins (emacs keymap arrow up/down goes through
    # multi-line by default and users expect that behaviour).
    if (( ${#kms[(r)viins]} > 0 )); then
        bindkey -M viins "^[[A" _smart_widget_history_up   2>/dev/null
        bindkey -M viins "^[[B" _smart_widget_history_down 2>/dev/null
    fi

    # Tab — handled by the native completion bridge (first Tab = complete,
    # subsequent = menu-complete cycle).
    local km2
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

    local km w
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

    # Tab + Shift+Tab (native bridge) → restore originals captured in native.zsh.
    if (( ${+functions[_smart_native_restore_original_bindings]} )); then
        _smart_native_restore_original_bindings
    fi
    # Unbind Shift+Tab (we own it; there's no "original" to restore).
    local km3
    for km3 in "${kms[@]}"; do
        bindkey -M "$km3" -r "^[[Z" 2>/dev/null
    done
    bindkey -M vicmd -r "^[[Z" 2>/dev/null

    return 0
}
