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

cleanup(){ tmux kill-session -t "$SESS" 2>/dev/null; rm -rf "$ZD" "$WORK"; }
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
slowtype(){ local s="$1" i; for ((i=0;i<${#s};i++)); do
    tmux send-keys -t "$SESS" -l "${s:$i:1}"; sleep 0.12; done; }
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
