#!/usr/bin/env zsh
# tests/test-repaint.zsh
#
# Regression guard for the *cost of one keystroke* on the terminal.
#
# WHY THIS FILE EXISTS
#   Every keystroke ends up in the display layer, and for a while that layer
#   ended with `zle -R "" ""` "to force a redraw of the new region_highlight".
#   Measured on the bytes zsh actually writes to a pty, one keystroke with a
#   two-line prompt:
#
#     with `zle -R "" ""`   96 bytes, containing a scroll-inducing newline, a
#                           vertical cursor move and a screen erase ON EVERY
#                           KEYSTROKE — and 32 bytes even with the ghost and
#                           the candidate list switched off, where stock zsh
#                           writes ONE byte for the same keystroke
#     without it            33 bytes for the same keystroke: the echo and the
#                           coloured ghost, nothing else
#
#   A newline plus a cursor-up that a terminal does not undo perfectly shows up
#   as an extra prompt line per keystroke — "typing one character starts a new
#   input line, without waiting for Enter" — and mixes the glyphs on the line
#   being typed.
#
#   No other layer can see this. The unit suites have no tty, and the tmux e2e
#   cannot see it either: tmux undoes the newline + cursor-up pair, so its
#   screen AND its scrollback come out identical. Only the raw byte stream
#   shows it, so this file drives a real interactive zsh through zsh/zpty and
#   reads exactly what the plugin wrote. Skips (exit 0) when zsh/zpty or
#   zsh/mapfile is unavailable.
#
# Invariant under test: ONE keystroke stays on ONE line. It may echo, it may
# paint the ghost, it may colour it — it must never advance to another line,
# move the cursor vertically, or erase the screen.

emulate -L zsh
setopt extended_glob no_warn_create_global

ROOT="${0:a:h:h}"
PASS=0
FAIL=0

if ! zmodload zsh/zpty 2>/dev/null; then
    print -r -- "SKIP: zsh/zpty is unavailable — cannot read the terminal byte stream"
    exit 0
fi
if ! zmodload zsh/mapfile 2>/dev/null; then
    print -r -- "SKIP: zsh/mapfile is unavailable — cannot read the capture verbatim"
    exit 0
fi

ZPTY_NAME="zsc_repaint_$$"
ZD=""                 # throwaway ZDOTDIR of the nested shell
CAP=""                # file holding the raw bytes of the last keystroke(s)

# _ok / _no -- tally
_ok() { (( PASS++ )); print -r -- "  PASS  $1" }
_no() { (( FAIL++ )); print -ru2 -- "  FAIL  $1  ${2:-}" }

# _show <bytes> -- one-line, escape-visible rendering for failure messages.
_show() {
    local s="$1" esc=$'\e'
    s="${s//$esc/<E>}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    print -r -- "${s[1,120]}"
}

# NOTE: every reader below pulls the bytes straight out of $mapfile, never
# through `$( )` — a command substitution strips trailing newlines, and a
# trailing newline is exactly one of the things this file is looking for.
assert_painted_ghost() {
    local b="${mapfile[$CAP]}"
    [[ "$b" == *"s -la /etc/"* ]] && _ok "ghost: the suggestion is written" \
                                 || _no "ghost: the suggestion is written" "got $(_show "$b")"
    [[ "$b" == *"38;5;110"* ]] && _ok "ghost: the suggestion is coloured" \
                              || _no "ghost: the suggestion is coloured" "got $(_show "$b")"
}

# assert_one_line <name> -- the keystroke must not leave the line it is on.
assert_one_line() {
    local name="$1" b="${mapfile[$CAP]}"
    local why=""
    [[ "$b" == *$'\n'* ]]          && why="a newline"
    [[ -z "$why" && "$b" == *$'\e'[0-9]#A* ]] && why="a cursor-up move"
    [[ -z "$why" && "$b" == *$'\e'[0-9]#B* ]] && why="a cursor-down move"
    [[ -z "$why" && "$b" == *$'\e'[0-9]#J* ]] && why="a screen erase"
    [[ -z "$why" ]] && _ok "$name" || _no "$name" "($why was written: $(_show "$b"))"
}

cleanup() {
    zpty -d "$ZPTY_NAME" 2>/dev/null
    [[ -n "$ZD" && -d "$ZD" ]] && rm -rf -- "$ZD"
}

# _session_start [extra-zshrc-lines] -- boot an interactive zsh on a pty.
# Fails the suite when the prompt never appears, so a silent boot can never
# leave the assertions below passing vacuously.
_session_start() {
    local extra="$1"
    ZD="$(mktemp -d /tmp/zsc_repaint.XXXXXX)"
    CAP="$ZD/last.bin"
    print -r -- ': 1700000000:0;ls -la /etc/' > "$ZD/.zsh_history"
    {
        print -r -- "HISTFILE=$ZD/.zsh_history"
        print -r -- 'HISTSIZE=2000'
        print -r -- 'SAVEHIST=2000'
        print -r -- "autoload -Uz compinit && compinit -u -d $ZD/.zcompdump"
        print -r -- "source $ROOT/zsh-smart-complete.plugin.zsh"
        [[ -n "$extra" ]] && print -r -- "$extra"
        # Two lines, the shape the shipped starship template renders.
        print -r -- "PROMPT=\$'L1> %n\\n:> '"
        print -r -- "RPROMPT=''"
    } > "$ZD/.zshrc"

    zpty -d "$ZPTY_NAME" 2>/dev/null
    zpty -b "$ZPTY_NAME" "env ZDOTDIR=$ZD HOME=$ZD TERM=xterm-256color zsh -i"

    local waited=0 boot=""
    while (( waited < 60 )); do
        boot+="$(_drain)"
        if [[ "$boot" == *':> '* ]]; then
            sleep 0.4          # let the boot's trailing bytes arrive
            _drain >/dev/null
            return 0
        fi
        sleep 0.25
        (( waited++ ))
    done
    _no "the nested zsh reached its prompt" "(boot=$(_show "$boot"))"
    return 1
}

# _drain -- everything the pty has produced right now (non-blocking).
_drain() {
    local out="" chunk
    while zpty -r -t "$ZPTY_NAME" chunk; do
        out+="$chunk"
    done
    print -rn -- "$out"
}

# _type <keys> -- send keys (no trailing newline), capture the raw bytes.
_type() {
    _drain >/dev/null
    : > "$CAP"
    zpty -w -n "$ZPTY_NAME" "$1"
    sleep 0.9
    _drain > "$CAP"
}

print -r -- "test-repaint: one keystroke must stay on one line"
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. A keystroke that yields a ghost paints it, in colour, on the SAME line.
# ---------------------------------------------------------------------------
if _session_start ""; then
    _type 'l'
    assert_painted_ghost
    assert_one_line "ghost: the keystroke stays on one line"
fi
cleanup

# ---------------------------------------------------------------------------
# 2. Keystrokes with nothing to suggest must not repaint the line either.
# ---------------------------------------------------------------------------
if _session_start ""; then
    _type 'z'; assert_one_line "no suggestion: 1st keystroke stays on one line"
    _type 'q'; assert_one_line "no suggestion: 2nd keystroke stays on one line"
fi
cleanup

# ---------------------------------------------------------------------------
# 3. With both channels off the plugin must be invisible: a keystroke costs its
#    own echo, exactly like stock zsh (measured: 1 byte vs 32 before the fix).
# ---------------------------------------------------------------------------
if _session_start $'SMART_MENU=false\nSMART_INLINE=false'; then
    _type 'z'
    assert_one_line "both off: the keystroke stays on one line"
    nbytes="${#${mapfile[$CAP]}}"
    if (( nbytes <= 2 )); then
        _ok "both off: the keystroke costs the echo only (${nbytes} bytes)"
    else
        _no "both off: the keystroke costs the echo only" "(${nbytes} bytes: $(_show "${mapfile[$CAP]}"))"
    fi
fi
cleanup

print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
