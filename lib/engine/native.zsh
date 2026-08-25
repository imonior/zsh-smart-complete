# lib/engine/native.zsh
#
# Native Completion bridge.
#
# THE RULE: We never call `compinit`. We never call `autoload compinit`.
# We never replay compdef. The user owns compinit in their .zshrc.
#
# Our job is: when the user presses Tab, we make sure that whatever
# completion the user already configured (git, docker, kubectl, ssh,
# homebrew, …) works as before. We are NOT a replacement for compsys.
#
# What this module actually provides:
#
#   1. _smart_native_have_compinit -- returns 0 iff the user has actually
#      loaded compinit (i.e. the `compdef` function exists and compsys
#      widgets are registered). We use this to decide whether to hand Tab
#      straight to `expand-or-complete` or just call self-insert.
#
#   2. _smart_native_complete -- widget. If compinit is present, forwards
#      to the original expand-or-complete (or menu-complete, whatever the
#      user had bound before we loaded). If not present, forwards to
#      self-insert so Tab still inserts a tab character (harmless).
#
#   3. _smart_native_save_original_bindings -- called during widget
#      installation. Captures whatever the user had bound to ^I (Tab) in
#      emacs, viins and vicmd so we can:
#        * call that exact widget on Tab
#        * restore it 100% on smart-disable
#
# Why this solves the "compinit hasn't been loaded" class of errors:
#
#   zsh-autocomplete forcibly runs compinit + compdef replay at plugin load.
#   If the user ran `zinit ice wait lucid` the widget functions exist but
#   compinit was never actually autoloaded → kaboom. We simply refuse to
#   believe compinit exists until compdef exists. If the user skips
#   compinit, that's their shell; Tab is a tab.
#
# Ubuntu 22.04 note: /usr/share/zsh/vendor-completions often ships with
# partial compinit shims that define `_apt` but not `compdef`. We handle
# that by checking for both compdef AND the _comps associative array that
# compinit initialises. Both must be present.

emulate -L zsh
setopt extended_glob no_warn_create_global

# Original user Tab bindings per keymap. Stored as strings like "widget-name"
# or empty if the key was unbound.
typeset -g _SMART_NATIVE_ORIG_TAB_EMACS=""
typeset -g _SMART_NATIVE_ORIG_TAB_VIINS=""
typeset -g _SMART_NATIVE_ORIG_TAB_VICMD=""

# Completion state flag: 0 = inactive, 1 = menu is showing.
typeset -gi _SMART_COMPLETION_ACTIVE=0

# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------

# _smart_native_have_compinit -- 0 if the user's shell has a working compsys.
_smart_native_have_compinit() {
    # compdef exists AND _comps (the completion function map) exists.
    (( ${+functions[compdef]} )) || return 1
    (( ${+parameters[_comps]} )) || return 1
    # Paranoia: make sure the map is actually an associative array.
    [[ "${(t)_comps}" == association* ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Original-binding capture + restore
# ---------------------------------------------------------------------------

# _smart_current_binding <keymap> <keyseq>
# Echoes the widget name or "" if unbound.
_smart_current_binding() {
    local km="$1" seq="$2"
    local out
    out=$(bindkey -M "$km" -- "$seq" 2>/dev/null) || { print -r -- ""; return 0; }
    # bindkey output: "^I" expand-or-complete
    # Strip the quoted prefix; take the second token.
    local rest="${out#*\"${seq}\" }"
    if [[ "$rest" == "$out" ]]; then
        # Some zsh builds echo without quotes: ^I expand-or-complete
        rest="${out#${seq} }"
    fi
    print -r -- "${rest%% *}"
}

_smart_native_save_original_bindings() {
    _SMART_NATIVE_ORIG_TAB_EMACS=$(_smart_current_binding emacs $'\t')
    _SMART_NATIVE_ORIG_TAB_VIINS=$(_smart_current_binding viins $'\t')
    _SMART_NATIVE_ORIG_TAB_VICMD=$(_smart_current_binding vicmd $'\t')
    return 0
}

# _smart_native_restore_original_bindings
_smart_native_restore_original_bindings() {
    local w
    w="$_SMART_NATIVE_ORIG_TAB_EMACS"
    if [[ -n "$w" ]]; then
        bindkey -M emacs -- $'\t' "$w" 2>/dev/null
    else
        bindkey -M emacs -r -- $'\t' 2>/dev/null
    fi
    w="$_SMART_NATIVE_ORIG_TAB_VIINS"
    if [[ -n "$w" ]]; then
        bindkey -M viins -- $'\t' "$w" 2>/dev/null
    else
        bindkey -M viins -r -- $'\t' 2>/dev/null
    fi
    w="$_SMART_NATIVE_ORIG_TAB_VICMD"
    if [[ -n "$w" ]]; then
        bindkey -M vicmd -- $'\t' "$w" 2>/dev/null
    else
        bindkey -M vicmd -r -- $'\t' 2>/dev/null
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Tab widget
# ---------------------------------------------------------------------------

# _smart_native_call_original <keymap_hint>
#
# Dispatch to the original widget for the currently active keymap.
# We look up $KEYMAP (set by ZLE) instead of the hint where possible.
_smart_native_call_original() {
    local hint_km="${1:-}"
    local km="${KEYMAP:-$hint_km}"
    local widget=""
    case "$km" in
        vicmd) widget="$_SMART_NATIVE_ORIG_TAB_VICMD" ;;
        viins|main) widget="$_SMART_NATIVE_ORIG_TAB_VIINS" ;;
        emacs|*)   widget="$_SMART_NATIVE_ORIG_TAB_EMACS" ;;
    esac

    if [[ -z "$widget" ]]; then
        # No original binding. Degrade gracefully: if compsys is alive, the
        # canonical widget is expand-or-complete; otherwise just insert tab.
        if _smart_native_have_compinit; then
            widget="expand-or-complete"
        else
            widget="self-insert"
        fi
    fi

    # If the captured widget no longer exists (plugin was unloaded etc.),
    # fall back to the same graceful default.
    if [[ -n "$widget" ]] && ! (( ${+widgets[$widget]} )) 2>/dev/null; then
        if _smart_native_have_compinit; then
            widget="expand-or-complete"
        else
            widget="self-insert"
        fi
    fi

    if (( ${+widgets[$widget]} )); then
        zle "$widget"
    else
        zle self-insert
    fi
}

# _smart_native_complete -- our public Tab widget.
#
# Implements the frozen three-key interaction model:
#   First Tab (inactive state)  → expand-or-complete (opens menu if multiple)
#   Subsequent Tab (active state) → menu-complete (cycle to next candidate)
#
# Side-effects:
#   * Clear inline suggestion ghost text (Tab ≠ suggestion channel)
#   * Set _SMART_COMPLETION_ACTIVE flag
_smart_native_complete() {
    # Clear inline display.
    (( ${+functions[_smart_display_clear]} )) && _smart_display_clear

    case "${SMART_COMPLETE}" in
        false|no|off|0|disabled)
            _smart_native_call_original emacs
            return $?
            ;;
    esac

    # Configure menu-select style on first use.
    if [[ "${SMART_NATIVE_MENU_SELECT}" == "true" ]] && \
       (( ${+functions[compinit]} )); then
        zstyle ':completion:*' menu select 2>/dev/null
        if [[ "${SMART_NATIVE_LIST_COLORS}" == "true" ]] && \
           (( ${+parameters[LS_COLORS]} )); then
            zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}" 2>/dev/null
        fi
    fi

    # First Tab: call original (expand-or-complete / complete-word).
    # Subsequent Tab: cycle candidates via menu-complete.
    if (( _SMART_COMPLETION_ACTIVE == 0 )); then
        _SMART_COMPLETION_ACTIVE=1
        _smart_native_call_original emacs
    else
        # Cycle to next candidate in the menu.
        if (( ${+widgets[menu-complete]} )); then
            zle menu-complete
        else
            _smart_native_call_original emacs
        fi
    fi
    return $?
}
zle -N _smart_native_complete 2>/dev/null

# ---------------------------------------------------------------------------
# Shift+Tab widget: reverse-menu-complete (cycle to previous candidate).
# ---------------------------------------------------------------------------
_smart_native_reverse_complete() {
    if (( ${+widgets[reverse-menu-complete]} )); then
        zle reverse-menu-complete
    else
        _smart_native_call_original emacs
    fi
    return $?
}
zle -N _smart_native_reverse_complete 2>/dev/null

# ---------------------------------------------------------------------------
# Reset completion state (called when leaving the completion channel).
# ---------------------------------------------------------------------------
_smart_native_reset_completion() {
    _SMART_COMPLETION_ACTIVE=0
    return 0
}
zle -N _smart_native_complete 2>/dev/null
