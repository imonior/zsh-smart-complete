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
#
# TWO HARNESS RULES, both learned the hard way (this file failed CI on Linux
# while passing on macOS because of the first one):
#   1. NEVER wait a fixed time and then read. Wait for the FIRST byte, then
#      keep reading until the pty goes quiet, so the capture is the whole
#      response to that keystroke. A constant sleep either cuts a late redraw
#      in half or reads nothing at all on a slow machine — and a blank capture
#      silently passes assert_one_line while failing everything else.
#   2. Every reader goes through $mapfile, never through `$( )`: a command
#      substitution strips trailing newlines, and a trailing newline is exactly
#      one of the things this file is looking for.

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
# The TERM every session in this file boots with. A variable because the
# capability probe below has to ask about this exact one, not about whatever the
# CI shell happens to export.
NESTED_TERM="xterm-256color"

# _ok / _no -- tally
_ok() { (( PASS++ )); print -r -- "  PASS  $1" }
_no() { (( FAIL++ )); print -ru2 -- "  FAIL  $1  ${2:-}" }

# _show <bytes> -- one-line, escape-visible rendering for failure messages.
_show() {
    local s="$1" esc=$'\e'
    s="${s//$esc/<E>}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    print -rn -- "${s[1,200]}"
}

# assert_painted_ghost -- the ghost is written, in the configured colour.
assert_painted_ghost() {
    local b="${mapfile[$CAP]}"
    local n=${#b}
    if (( n == 0 )); then
        _no "ghost: the suggestion is written" "(the pty produced NO bytes — the harness never saw a redraw)"
        _no "ghost: the suggestion is coloured" "(nothing was captured)"
        return
    fi
    [[ "$b" == *"s -la /etc/"* ]] && _ok "ghost: the suggestion is written (${n} bytes)" \
                                 || _no "ghost: the suggestion is written" "(${n} bytes: $(_show "$b"))"
    [[ "$b" == *"38;5;110"* ]] && _ok "ghost: the suggestion is coloured" \
                              || _no "ghost: the suggestion is coloured" "(colors=${_tf:-?}, ${n}B $(_show "$b"))"
}

# assert_one_line <name> -- the keystroke must not leave the line it is on.
# A blank capture is a FAILURE, not a pass: it means the harness saw nothing,
# so the invariant was never actually exercised.
assert_one_line() {
    local name="$1" b="${mapfile[$CAP]}"
    # NOTE: the length is taken in its OWN statement on purpose. Within a single
    # `local`, a later expansion does not see an assignment made earlier in the
    # same command: `local b="x" n=${#b}` leaves n at 0 while b is "x"
    # (measured on zsh 5.9). Derived in one statement, n would be 0 for every
    # capture, and the "no bytes" branch below would fire on a perfect one.
    local n=${#b} why=""
    if (( n == 0 )); then
        _no "$name" "(the pty produced NO bytes — the harness never saw a redraw)"
        return
    fi
    [[ "$b" == *$'\n'* ]]                       && why="a newline"
    [[ -z "$why" && "$b" == *$'\e'[0-9]#A* ]]   && why="a cursor-up move"
    [[ -z "$why" && "$b" == *$'\e'[0-9]#B* ]]   && why="a cursor-down move"
    [[ -z "$why" && "$b" == *$'\e'[0-9]#J* ]]   && why="a screen erase"
    [[ -z "$why" ]] && _ok "$name (${n} bytes)" \
                    || _no "$name" "($why was written, ${n} bytes: $(_show "$b"))"
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
    chmod go-w "$ZD"
    CAP="$ZD/last.bin"
    print -r -- ': 1700000000:0;ls -la /etc/' > "$ZD/.zsh_history"
    {
        print -r -- "HISTFILE=$ZD/.zsh_history"
        print -r -- 'HISTSIZE=2000'
        print -r -- 'SAVEHIST=2000'
        # `-u` is the documented "use what you find without asking" flag; `-C`
        # only skips the security check when the dump file ALREADY exists, so it
        # would still ask in a fresh directory.
        print -r -- "autoload -Uz compinit && compinit -u -d $ZD/.zcompdump"
        # Pin the line length and the ghost colour. Without this the assertion
        # "the ghost is coloured" depends on terminfo lookup plus the
        # auto-detection, and a runner whose TERM database answers differently
        # fails a test that is not about colour at all. Colour selection itself
        # is covered by tests/test-menu.zsh. What the database answers for the
        # nested TERM is reported with every colour failure, below.
        print -r -- "SMART_SUGGEST_COLOR='fg=110'"
        print -r -- "source $ROOT/zsh-smart-complete.plugin.zsh"
        [[ -n "$extra" ]] && print -r -- "$extra"
        # Two lines, the shape the shipped starship template renders. The size
        # is set explicitly because a pty starts at 0x0 and the fallback is the
        # emulator's business, not ours.
        print -r -- "stty rows 24 cols 80 2>/dev/null"
        print -r -- "PROMPT=\$'L1> %n\\n:> '"
        print -r -- "RPROMPT=''"
    } > "$ZD/.zshrc"

    zpty -d "$ZPTY_NAME" 2>/dev/null
    # `-d` is NO_GLOBAL_RCS: skip /etc/zsh/* but still read $ZDOTDIR/.zshrc. The
    # distro's global rc is not ours to depend on, and on an Ubuntu runner its
    # plain `compinit` stops on "Ignore insecure directories ... [y/n]?" (the
    # image leaves a directory in fpath group-writable), which blocks the shell
    # before it ever prints a prompt. Measured: without -d every session failed
    # its boot on Linux while macOS was fine.
    zpty -b "$ZPTY_NAME" "env ZDOTDIR=$ZD HOME=$ZD TERM=$NESTED_TERM zsh -i -d"

    local waited=0 boot="" answered=0
    while (( waited < 100 )); do
        boot+="$(_drain)"
        if [[ "$boot" == *':> '* ]]; then
            _read_until_quiet >/dev/null   # let the boot's trailing bytes arrive
            return 0
        fi
        # A startup file is allowed to ask a question before printing a prompt.
        # The pty is non-blocking, so nothing would ever answer it and the boot
        # would simply time out. Answer it, say so, and keep waiting — silently
        # hanging is the one outcome a harness must never have.
        if (( ! answered )) && [[ "$boot" == *"Ignore insecure directories"* ]]; then
            zpty -w "$ZPTY_NAME" "y"
            print -r -- "  note: a startup prompt asked about insecure completion directories; answered y"
            answered=1
        fi
        sleep 0.1
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

# _read_until_quiet -- wait for the FIRST byte (up to 10s), then keep reading
# until four consecutive quiet windows (~0.6s) pass. This is what makes the
# capture the complete response to one keystroke instead of whatever happened
# to land inside a fixed sleep.
_read_until_quiet() {
    local out="" chunk waited=0 idle=0 before=0
    while (( waited < 100 )); do
        while zpty -r -t "$ZPTY_NAME" chunk; do out+="$chunk"; done
        (( ${#out} )) && break
        sleep 0.1
        (( waited++ ))
    done
    while (( idle < 4 )); do
        sleep 0.15
        before=${#out}
        while zpty -r -t "$ZPTY_NAME" chunk; do out+="$chunk"; done
        if (( ${#out} == before )); then (( idle++ )); else idle=0; fi
    done
    print -rn -- "$out"
}

# _type <keys> -- send keys (no trailing newline), capture the raw bytes.
_type() {
    _drain >/dev/null
    : > "$CAP"
    zpty -w -n "$ZPTY_NAME" "$1"
    _read_until_quiet > "$CAP"
}

# One line of environment, so a failure that only happens on one platform can
# be told apart from a real regression without re-running it there. The nested
# shell is this same zsh binary.
#
# The colour count is queried with the TERM the nested session boots with,
# because that is the lookup ZLE performs. When terminfo cannot answer, zsh
# drops EVERY attribute from the byte stream — the ghost still appears, just
# uncoloured, which is indistinguishable from a plugin that stopped painting it.
# A minimal container's terminfo set is exactly where that happens, so the
# number is part of the failure message, not just this line: the CI annotation
# carries assertion output and nothing else.
_tf="$(TERM=$NESTED_TERM zsh -f -c \
    'zmodload -F zsh/terminfo p:terminfo 2>/dev/null && print -r -- "${terminfo[colors]:-unset}"' \
    2>/dev/null)"
[[ -n "$_tf" ]] || _tf="no-answer"
print -r -- "test-repaint: one keystroke must stay on one line"
print -r -- "  env: zsh $ZSH_VERSION, $OSTYPE, nested TERM=$NESTED_TERM, terminfo colors=$_tf"
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
    nbytes=${#${mapfile[$CAP]}}
    if (( nbytes >= 1 && nbytes <= 2 )); then
        _ok "both off: the keystroke costs the echo only (${nbytes} bytes)"
    else
        _no "both off: the keystroke costs the echo only" "(${nbytes} bytes: $(_show "${mapfile[$CAP]}"))"
    fi
fi
cleanup

print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
