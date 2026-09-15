#!/usr/bin/env bash
#
# tests/e2e-tmux.sh — end-to-end keybinding verification in a REAL terminal.
#
# The unit tests exercise pure logic; they cannot tell you whether a keystroke
# actually reaches a widget. This drives a real `zsh -i` inside a tmux pane and
# asserts on the RENDERED SCREEN (tmux capture-pane), not on the echoed line:
# the echoed line cannot distinguish "buffer = git status" (accepted) from
# "ghost = git status" (not accepted).
#
# Acceptance is therefore proven by the COMMAND'S OUTPUT — e.g. with
# `echo alpha beta` in the history and `echo al` typed, accepting one word runs
# `echo alpha` and prints exactly `alpha`.
#
# Requires: tmux, zsh. Skips (exit 0) when tmux is unavailable, so it is safe to
# run from a mixed CI matrix.
#
#   ./tests/e2e-tmux.sh [path-to-repo]      # defaults to the repo root
#
set -u

REPO="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"

if ! command -v tmux >/dev/null 2>&1; then
    echo "SKIP: tmux not found — cannot verify keybindings on a real screen"
    exit 0
fi
if [[ ! -f "$REPO/zsh-smart-complete.plugin.zsh" ]]; then
    echo "FAIL: $REPO does not look like the plugin repo" >&2
    exit 1
fi

SESS="zsc_e2e_$$"
ZD="$(mktemp -d "${TMPDIR:-/tmp}/zsc_e2e.XXXXXX")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zsc_work.XXXXXX")"   # probe cwd: NOT a git repo
BIG=""                                                  # 1200-entry dir, created in 3c
# Deliberately under /tmp, not $TMPDIR: on macOS $TMPDIR is a ~65-character
# /var/folders/... path, and typing one character at a time through a live
# popup costs ~35ms — a path that long takes ~2.5s to echo, which makes any
# fixed sleep in this file race the echo instead of testing the plugin.

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# Seeded history: the suggestion engine reads in-memory history, so an empty
# HISTFILE yields zero candidates and every "no suggestion" assertion becomes a
# false negative. `echo alpha beta` is the one-word-accept probe.
cat > "$ZD/.zsh_history" <<'EOF'
: 1700000000:0;git status
: 1700000001:0;git status --short
: 1700000002:0;git switch main
: 1700000003:0;echo alpha beta
EOF

cat > "$ZD/.zshrc" <<EOF
HISTFILE=$ZD/.zsh_history
HISTSIZE=2000
SAVEHIST=2000
autoload -Uz compinit && compinit -u -d $ZD/.zcompdump
source $REPO/zsh-smart-complete.plugin.zsh
PROMPT='READY> '
EOF

cleanup(){ tmux kill-session -t "$SESS" 2>/dev/null; rm -rf "$ZD" "$WORK" "${BIG:-}"; }
trap cleanup EXIT

tmux kill-session -t "$SESS" 2>/dev/null
tmux new-session -d -s "$SESS" -x 140 -y 40 -c "$WORK" \
    "env ZDOTDIR=$ZD TERM=xterm-256color zsh -i"
sleep 1.3

pane(){ tmux capture-pane -t "$SESS" -p; }
key(){  tmux send-keys -t "$SESS" "$1"; }
hex(){  tmux send-keys -t "$SESS" -H "$@"; }
# Human-paced typing. A zero-delay burst models a paste, not a person, and the
# plugin's throttle is keyed off measured cost.
#
# It also WAITS for the screen to catch up. A live popup costs ~35ms per
# keystroke, so the echo trails the input; returning as soon as the last byte is
# sent lets the next key land mid-line, which looks exactly like a lost
# keystroke but is not one.
slowtype(){ local s="$1" i k line; for ((i=0;i<${#s};i++)); do
    tmux send-keys -t "$SESS" -l "${s:$i:1}"; sleep 0.12; done
    for ((k=0;k<30;k++)); do
        sleep 0.15
        line="$(pane | grep -o 'READY> .*' | tail -1)"
        [[ ${#line} -ge $(( ${#s} + 7 )) ]] && break
    done
}
# Candidate lists are drawn BELOW the prompt, so count non-empty rows there.
# Never match candidate text: you typed it, so it is on screen regardless.
rows_below_prompt(){
    local P PL
    P="$(pane)"; PL="$(grep -nF 'READY>' <<<"$P" | tail -1 | cut -d: -f1)"
    [[ -z "${PL:-}" ]] && { echo 0; return; }
    awk -v n="$PL" 'NR>n && NF>0' <<<"$P" | wc -l | tr -d ' '
}
reset_line(){ key C-c; sleep 0.35; }

echo "== 0. boot =="
grep -qF 'READY>' <<<"$(pane)" && ok "prompt rendered" || no "prompt rendered"

echo "== 1. inline ghost suggestion while typing =="
reset_line; slowtype 'git s'; sleep 1.0
grep -qF 'git status' <<<"$(pane)" && ok "ghost 'git status' painted" || no "ghost not painted"

echo "== 2. type-to-popup: multi-match word lists candidates =="
reset_line; slowtype 'git st'; sleep 1.2
R=$(rows_below_prompt); [ "$R" -ge 1 ] && ok "popup below prompt ($R rows)" || no "no popup for 'git st'"
reset_line; slowtype 'git sta'; sleep 1.2
R=$(rows_below_prompt); [ "$R" -ge 1 ] && ok "popup survives narrowing ($R rows)" || no "popup lost on 'git sta'"

echo "== 3. by design: a single match yields to the ghost, no list =="
reset_line; slowtype 'git stat'; sleep 1.2
R=$(rows_below_prompt)
if [ "$R" -eq 0 ] && grep -qF 'git status' <<<"$(pane)"; then
    ok "1 match -> list dropped, ghost takes over"
else
    no "'git stat': rows=$R (expected 0 rows + ghost)"
fi

echo "== 3b. BUFFER INTEGRITY: typing must never lose a character =="
# The regression this guards, and why it lives here rather than in the unit
# tests: the popup used to scope-assign LISTMAX=-1 around its listing call,
# which corrupts ZLE's next input read and silently ate ONE KEYSTROKE per
# listing. Nothing in sections 1-3 can see that — the popup still appeared, the
# ghost still painted, every geometry assertion still passed; only the user's
# typing was broken (`git status` arrived as `gitstatus`, `echo hello` as
# `eco hello`). Proving it needs a real terminal and a real buffer.
#
# We compare the PROMPT LINE, not the executed output: the ghost suggestion is
# painted after the cursor, so demanding an exact match would fail whenever a
# suggestion is live. A prefix match is the right test and still catches a
# dropped character anywhere in what was typed (a dropped char shifts the rest
# left, so the prefix stops matching).
#
# 0.40s per character is deliberate: the bug reproduced at 0.30s and 0.45s in
# the A/B that found it. Typing faster than the failure mode only produces a
# false pass, so the pacing is part of the test.
typed_line(){ pane | grep -o 'READY> .*' | tail -1 | sed 's/^READY> //'; }
integrity(){  # <text>
    local text="$1" i got
    reset_line
    for ((i=0;i<${#text};i++)); do
        tmux send-keys -t "$SESS" -l "${text:$i:1}"; sleep 0.40
    done
    sleep 0.9
    got="$(typed_line)"
    if [[ "$got" == "$text"* ]]; then
        ok "no keystroke lost: '$text'"
    else
        no "KEYSTROKE LOST: typed '$text' but buffer holds '$got'"
    fi
}
integrity 'git status'
integrity 'ls -la'
integrity 'echo hello'
integrity 'print -r -- MARK1 hello'

# The strongest form of the same claim: what the shell ACTUALLY ran. Under the
# bug, `echo hello` executed as `eco hello` and zsh printed
# `command not found: eco` — a completely different command.
integrity_exec(){  # <text> <output line that proves it ran>
    local text="$1" want="$2" i
    reset_line
    for ((i=0;i<${#text};i++)); do
        tmux send-keys -t "$SESS" -l "${text:$i:1}"; sleep 0.40
    done
    sleep 0.7
    key Enter; sleep 1.4
    if grep -qx "$want" <<<"$(pane)"; then
        ok "'$text' executed intact (printed '$want')"
    else
        no "'$text' did not execute intact (expected '$want' on its own line)"
    fi
    if grep -q 'command not found' <<<"$(pane)"; then
        no "a corrupted command was executed ('command not found')"
    fi
}
integrity_exec 'echo hello' 'hello'

echo "== 3c. huge directory: cap the list, never prompt, never drop a key =="
# The direction that a LISTMAX-based fix made WORSE: with a 1200-entry
# directory the default-listmax path was the clean one and LISTMAX=-1 was the
# one that ate keys. The shipped fix declines to draw a list this big at all
# (SMART_MENU_MAX_MATCHES=100), which is the only setting that was clean for
# both short and long lists.
BIG="$(mktemp -d /tmp/zsc_big.XXXXXX)"
i=1
while [ "$i" -le 1200 ]; do : > "$BIG/entry_$i"; i=$((i+1)); done

# Send a whole command and POLL until the prompt line has echoed it, instead of
# sleeping a fixed amount. A live popup costs ~35ms per keystroke, so a paste
# of `cd <path>` needs over a second to land; a fixed short sleep lets the next
# keystroke arrive mid-line, which looks exactly like a lost keystroke but is
# not one. (That false failure is how this helper came to exist.)
send_line(){  # <command>
    local cmd="$1" want line k
    reset_line
    tmux send-keys -t "$SESS" -l "$cmd"
    want=$(( ${#cmd} + 1 ))
    for ((k=0;k<40;k++)); do
        sleep 0.25
        line="$(typed_line)"
        [[ ${#line} -ge $want ]] && break
    done
    key Enter; sleep 1.1
}
send_line "cd $BIG"
# Prove the cd landed; otherwise "the big directory" assertion below is vacuous.
reset_line; send_line 'pwd'
if grep -qx "$BIG" <<<"$(pane)"; then
    ok "cd landed in the 1200-entry directory"
else
    no "cd did not land in the big directory — the cap assertion would be vacuous"
fi
integrity 'ls entry'
if grep -q 'do you wish to see all' <<<"$(pane)"; then
    no "zsh asked 'do you wish to see all N possibilities' on a big directory"
else
    ok "no 'do you wish to see all' prompt on a 1200-entry directory"
fi
send_line "cd $WORK"

echo "== 3d. ↑ / ↓ keep native history navigation (SMART_MENU_HISTORY_KEYS=false) =="
# The default must not hijack the arrows: with an empty line ↑ must still recall
# the previous command rather than starting a prefix search.
reset_line; slowtype 'echo histprobe'; sleep 0.3; key Enter; sleep 1.0
reset_line
hex 1b 5b 41; sleep 0.7      # CSI up-arrow
if grep -qF 'echo histprobe' <<<"$(typed_line)"; then
    ok "↑ recalls history when the line is empty"
else
    no "↑ did not recall history: [$(typed_line)]"
fi
reset_line

echo "== 3e. opt-in: ↑ prefix-searches history (SMART_MENU_HISTORY_KEYS=true) =="
# The zsh-autocomplete headline behaviour, available on request. The test is
# built to DISCRIMINATE prefix search from plain history recall: the most recent
# history entry does NOT match the prefix we type, so a stock ↑ would recall the
# wrong line and the executed output would differ.
# Section headers warn against trusting the echoed line — so acceptance is
# proven by what the shell PRINTS, after Enter.
reset_line; slowtype 'echo PREFIXALPHA two'; sleep 0.3; key Enter; sleep 0.9
reset_line; slowtype 'echo ZZZ last';        sleep 0.3; key Enter; sleep 0.9
reset_line
tmux send-keys -t "$SESS" -l "smart-disable; SMART_MENU_HISTORY_KEYS=true; smart-enable"
sleep 0.4; key Enter; sleep 1.2
reset_line; slowtype 'echo PREFIXALPHA'; sleep 0.6
hex 1b 5b 41; sleep 0.9          # ↑ → prefix search
key Enter; sleep 1.3
if grep -qx 'PREFIXALPHA two' <<<"$(pane)"; then
    ok "↑ prefix-searched history while the line was non-empty"
elif grep -qx 'ZZZ last' <<<"$(pane)"; then
    no "↑ did a plain history recall, not a prefix search"
else
    no "↑ prefix search inconclusive (pane did not show either expected line)"
fi
reset_line
tmux send-keys -t "$SESS" -l "smart-disable; SMART_MENU_HISTORY_KEYS=false; smart-enable"
sleep 0.4; key Enter; sleep 1.0
reset_line

echo "== 4. plain right arrow, SS3 encoding (what xterm-256color sends) =="
reset_line; slowtype 'git s'; sleep 1.0
hex 1b 4f 43; sleep 0.6; key Enter; sleep 1.3
P="$(pane)"
grep -qF 'not a git repository' <<<"$P" && ok "SS3 → accepted the suggestion" \
  || { grep -qF "git: 's' is not a git command" <<<"$P" \
       && no "SS3 → not accepted (ran 'git s')" || no "SS3 → inconclusive"; }

echo "== 5. plain right arrow, CSI encoding =="
reset_line; slowtype 'git s'; sleep 1.0
hex 1b 5b 43; sleep 0.6; key Enter; sleep 1.3
grep -qF 'not a git repository' <<<"$(pane)" && ok "CSI → accepted the suggestion" \
  || no "CSI → not accepted"

echo "== 6. Alt+Right accepts exactly ONE word, in every encoding =="
while read -r label bytes; do
    reset_line; slowtype 'echo al'; sleep 1.0
    hex $bytes; sleep 0.8; key Enter; sleep 1.2
    P="$(pane)"
    if grep -qx 'alpha' <<<"$P"; then
        ok "Alt+Right ($label) accepted one word -> printed 'alpha'"
    elif grep -qx 'alpha beta' <<<"$P"; then
        no "Alt+Right ($label) accepted the WHOLE suggestion"
    else
        no "Alt+Right ($label) inconclusive"
    fi
done <<'ENC'
CSI-1;3C 1b 5b 31 3b 33 43
ESC-ESC-CSI 1b 1b 5b 43
ESC-ESC-SS3 1b 1b 4f 43
ENC

echo "== 7. kill switch =="
reset_line; slowtype 'smart-menu off'; sleep 0.2; key Enter; sleep 1.0
reset_line; slowtype 'git st'; sleep 1.2
R=$(rows_below_prompt); [ "$R" -eq 0 ] && ok "menu off -> no popup" || no "menu off -> still listing ($R rows)"
reset_line; slowtype 'smart-menu on'; sleep 0.2; key Enter; sleep 0.8
reset_line; slowtype 'git st'; sleep 1.2
R=$(rows_below_prompt); [ "$R" -ge 1 ] && ok "menu on -> popup returns ($R rows)" || no "menu on -> no popup"

echo "== 8. Tab completion unaffected =="
reset_line; slowtype 'git swit'; sleep 0.6; key Tab; sleep 1.0
grep -qF 'switch' <<<"$(pane)" && ok "Tab still completes (switch)" || no "Tab completion broken"

echo "-----"
echo "E2E TOTAL PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
