# zsh-smart-complete.plugin.zsh
#
# Main entry point. Loaded by any plugin manager (Zinit / Antidote / Oh My
# Zsh / znap / manual source).
#
# This file is intentionally small. It:
#   1. Guards against double sourcing.
#   2. Resolves $SMART_ROOT so lib files can be found.
#   3. Sources every module in dependency order.
#   4. Registers the tiny public CLI (smart-status/enable/disable/reindex).
#   5. Defers the first history-index build to a precmd so plugin load time
#      is not impacted.
#
# DESIGN RULES FOR THIS FILE (and the whole plugin):
#   * We NEVER call `compinit` or `autoload compinit`.
#     It is the USER's responsibility in .zshrc.
#   * We NEVER hook `line-pre-redraw`.
#     Suggestion computation is driven by the input-event widgets in
#     lib/event/zle.zsh, not by every ZLE redraw.
#   * We NEVER depend on zsh-autocomplete, zsh-autosuggestions or Atuin.
#     They are orthogonal; Atuin is an OPTIONAL history backend.
#   * We NEVER leak names without the `_smart` / `SMART_` prefix.

emulate -L zsh
setopt extended_glob no_warn_create_global

# ---------------------------------------------------------------------------
# Double-source guard
# ---------------------------------------------------------------------------
if (( ${+SMART_SOURCED} )); then
    return 0
fi
typeset -g SMART_SOURCED=1

# ---------------------------------------------------------------------------
# Root resolution
# ---------------------------------------------------------------------------
# Works when sourced directly, via symlink, or via ${0} inside a function.
SMART_ROOT="${${(%):-%x}:a:h}"
(( ${+SMART_ROOT} )) || SMART_ROOT="${0:a:h}"
typeset -g SMART_ROOT

# ---------------------------------------------------------------------------
# Internal loader -- source relative to $SMART_ROOT, silently skip missing.
# ---------------------------------------------------------------------------
_smart_source() {
    local f
    for f in "$@"; do
        f="${SMART_ROOT}/${f}"
        [[ -r "$f" ]] && source -- "$f"
    done
}

# ---------------------------------------------------------------------------
# Load order (strict dependency order)
#
#   1. config         -- defaults + feature flags (depends on nothing)
#   2. state          -- central _SMART_STATE container
#   3. history/zsh     -- zsh backend (fc-based, depends on state)
#   4. history/atuin   -- atuin backend (depends on state)
#   5. history/history -- core dispatcher (depends on backends + state)
#   6. engine/ranking  -- scoring functions (depends on nothing)
#   7. engine/suggest  -- suggestion engine (depends on history + ranking + state)
#   8. engine/native   -- native completion bridge (depends on state only)
#   9. display        -- inline rendering (depends on state only)
#  10. event/zle      -- widgets + keymap (depends on everything above)
# ---------------------------------------------------------------------------
_smart_source \
    lib/config.zsh \
    lib/state.zsh \
    lib/history/zsh.zsh \
    lib/history/atuin.zsh \
    lib/history/history.zsh \
    lib/engine/ranking.zsh \
    lib/engine/suggest.zsh \
    lib/engine/native.zsh \
    lib/display/display.zsh \
    lib/event/zle.zsh

unfunction _smart_source 2>/dev/null

# ---------------------------------------------------------------------------
# Public CLI
# ---------------------------------------------------------------------------

# smart-status -- print runtime summary (safe to call from anywhere).
smart-status() {
    print -r -- "zsh-smart-complete $(cat -- "${SMART_ROOT}/VERSION" 2>/dev/null || print -r -- unknown)"
    print -r -- "  enabled:          $(_smart_state_get enabled)"
    print -r -- "  suggest:          ${SMART_SUGGEST}   inline: ${SMART_INLINE}"
    print -r -- "  complete:         ${SMART_COMPLETE}"
    print -r -- "  history backend:  ${SMART_HISTORY_BACKEND}"
    print -r -- "  history indexed:  $(_smart_state_get history.count)"
    print -r -- "  last rebuild:     $(_smart_state_get history.rebuilt_at)"
    print -r -- "  last suggestion:  [$(_smart_state_get suggestion.text)]"
}

# smart-disable -- tear out widgets, stop computing suggestions.
smart-disable() {
    _smart_event_unbind 2>/dev/null
    _smart_display_clear 2>/dev/null
    _smart_state_set enabled 0
    zle reset-prompt 2>/dev/null
    return 0
}

# smart-enable -- re-install after disable.
smart-enable() {
    _smart_state_set enabled 1
    _smart_event_bind 2>/dev/null
    # Build the index lazily if it hasn't been built yet.
    if (( $(_smart_state_get history.count) == 0 )); then
        _smart_history_rebuild 2>/dev/null
    fi
    zle reset-prompt 2>/dev/null
    return 0
}

# smart-reindex -- drop + rebuild the history index (useful after huge
# `fc -R` operations or on long-running shells).
smart-reindex() {
    _smart_history_rebuild
    print -r -- "history index rebuilt: $(_smart_state_get history.count) entries"
    return 0
}

# smart-toggle -- Ctrl+G. Disable if enabled; enable if disabled.
smart-toggle() {
    if (( $(_smart_state_get enabled) == 1 )); then
        smart-disable
    else
        smart-enable
    fi
}
zle -N smart-toggle 2>/dev/null

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
# Set the initial state. We do NOT build the history index synchronously here
# because `fc` can be slow on million-line histfiles. Instead:
#   * The index is built on the first precmd (idle moment after the prompt).
#   * If someone types before that happens, suggestion falls back to a
#     tiny on-the-fly lookup and schedules the full build.
# Set the initial enabled state via a plain case statement so even exotic
# zsh builds (Ubuntu 22.04 packaged, etc.) handle it without modifier errors.
case "${SMART_ENABLED}" in
    false|no|off|0|disabled)  _smart_state_set enabled 0 ;;
    *)                        _smart_state_set enabled 1 ;;
esac

# Defer the first index build + widget binding to the first precmd, so the
# plugin appears to load instantly even with huge history files.
_smart_bootstrap_once() {
    # Do not auto-build if user disabled the plugin.
    if (( $(_smart_state_get enabled) == 1 )); then
        _smart_history_rebuild 2>/dev/null
        _smart_event_bind      2>/dev/null
    fi
    # Remove self so we run exactly once.
    precmd_functions=("${(@)precmd_functions:#_smart_bootstrap_once}")
    unfunction _smart_bootstrap_once 2>/dev/null
}
precmd_functions+=(_smart_bootstrap_once)
