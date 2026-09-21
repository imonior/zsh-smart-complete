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
RD=""                                                   # recent-dirs fixture, created below
# Deliberately under /tmp, not $TMPDIR: on macOS $TMPDIR is a ~65-character
# /var/folders/... path, and typing one character at a time through a live
# popup costs ~35ms — a path that long takes ~2.5s to echo, which makes any
# fixed sleep in this file race the echo instead of testing the plugin.

# Recent-directory fixture (scenarios 8b/9). The database is written exactly the
# way `chpwd_recent_filehandler` writes it — one $'...'-quoted path per line — so
# the parser is exercised against the real format rather than a convenient one.
# `never-was` deliberately does not exist on disk and must be filtered out.
RD="$(mktemp -d /tmp/zsc_rd.XXXXXX)"
mkdir -p "$RD/proj-alpha" "$RD/proj-beta"
RDB="$RD/db"
zsh -fc 'p=( "$1/proj-alpha" "$1/proj-beta" "$1/never-was" ); print -rl ${(qqqq)p}' _ "$RD" > "$RDB"
# Tab-completion probe for 8b: completing `echo tabprobe` to this name makes the
# command print a line that is exactly `tabprobe-one`. It lives in SHORT because
# scenarios 8b/9 have to `cd` to it BY TYPING: a burst `send-keys -l` of a long
# path is dropped character by character (each keystroke triggers a redraw), and
# macOS $TMPDIR is ~65 characters. Never type a long path into a live popup.
SHORT="/tmp/zsc_e2e_short.$$"
mkdir -p "$SHORT"
touch "$SHORT/tabprobe-one"

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
zstyle ':chpwd:' recent-dirs-file $RDB
source $REPO/zsh-smart-complete.plugin.zsh
# Probe (scenario 12/13): dump region_highlight verbatim on F12. It must be
# bound AFTER the plugin so the plugin's ^@-^_ self-insert sweep cannot eat it,
# and its name must not collide with any plugin widget.
# NOTE: this heredoc is UNQUOTED, so bash performs parameter expansion AND
# command substitution on it while writing the file -- comments included. There
# are two ways that silently ruins the whole run:
#   1. an unescaped array expansion aborts under set -u ("unbound variable:
#      region_highlight[@]"), so nothing gets written at all; and
#   2. a stray backtick pair RUNS that command with the heredoc as its stdin.
#      Observed: a backtick-wrapped cat swallowed the rest of the body and then
#      blocked forever, hanging the suite before scenario 0 ever printed.
# Either way .zshrc is never created, zsh boots with its DEFAULT prompt, the
# plugin is never sourced, and every "nothing happened" assertion passes
# vacuously (measured: PASS=10 FAIL=35, all of it this one comment block).
# So: no backticks anywhere in this heredoc, and the expansion below stays
# escaped. Do not write the raw form here.
_dump_rh() { print -rl -- "\${region_highlight[@]}" > "$ZD/rh.txt"; }
zle -N _dump_rh
bindkey -M emacs '^[[24~' _dump_rh
PROMPT='READY> '
EOF

# Remove only paths we actually created: an unquoted/empty arg would turn the
# `rm -rf` into a no-target command, and a guard hook then reports the CURRENT
# DIRECTORY as the target (observed: 1030 entries = the whole repo). Never let
# a cleanup helper have an empty operand.
cleanup(){
    local d
    tmux kill-session -t "$SESS" 2>/dev/null
    for d in "$ZD" "$WORK" "${BIG:-}" "${RD:-}" "${SHORT:-}" "${SC:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"
    done
}
trap cleanup EXIT

tmux kill-session -t "$SESS" 2>/dev/null
tmux new-session -d -s "$SESS" -x 140 -y 40 -c "$WORK" \
    "env ZDOTDIR=$ZD TERM=xterm-256color zsh -i"
# Poll for the prompt instead of a fixed sleep: zsh cold-boot + sourcing the
# plugin can exceed any single hard-coded delay on a loaded machine, which made
# the "prompt rendered" assertion flaky. Wait up to ~10s.
for _ in $(seq 1 40); do
    tmux capture-pane -t "$SESS" -p 2>/dev/null | grep -qF 'READY>' && break
    sleep 0.25
done

# The harness is only as good as its own two files. A full disk makes the `cat >`
# above fail silently; zsh then boots with its DEFAULT prompt (%n@%m %1~ %#),
# never sources the plugin, and every "nothing happened" assertion passes
# vacuously. Measured 2026-09-19: one run reported PASS=10 FAIL=35 where all 35
# were the disk, not the plugin -- a 12-minute misdiagnosis. Fail loudly, once.
for f in "$ZD/.zshrc" "$ZD/.zsh_history"; do
    [[ -s "$f" ]] || {
        echo "FAIL: harness file $f was not written - aborting before the run." >&2
        echo "      (a full disk silently drops it; free space and retry)" >&2
        df -h "$ZD" >&2
        exit 1
    }
done
# Non-empty is not enough: an unescaped expansion inside the unquoted heredoc
# makes bash truncate .zshrc at that line, which still yields a non-empty file.
# Assert the two markers that prove the file is COMPLETE.
# The marker must NOT include the closing quote: the heredoc writes
# PROMPT='READY> ' (space before the quote), so PROMPT='READY>' would never
# match and the guard would abort a perfectly good run (observed).
for marker in "source $REPO/zsh-smart-complete.plugin.zsh" "PROMPT='READY>"; do
    grep -qF -- "$marker" "$ZD/.zshrc" || {
        echo "FAIL: $ZD/.zshrc is truncated - missing [$marker]." >&2
        echo "      (unquoted heredoc expanded something undefined under set -u)" >&2
        echo "      ---- actual file content ----" >&2
        sed -n l "$ZD/.zshrc" >&2
        exit 1
    }
done
if ! tmux capture-pane -t "$SESS" -p 2>/dev/null | grep -qF 'READY>'; then
    echo "FAIL: the harness zsh never rendered its prompt, so the plugin was never" >&2
    echo "      sourced (the signature of a failed \$ZD/.zshrc write). Aborting." >&2
    tmux capture-pane -t "$SESS" -p 2>/dev/null | tail -6 >&2
    exit 1
fi

pane(){ tmux capture-pane -t "$SESS" -p; }
# Same, but WITH the terminal escape sequences (SGR attributes). `pane`
# strips them, so it can never tell a coloured ghost from a plain one.
pane_e(){ tmux capture-pane -t "$SESS" -p -e; }
key(){  tmux send-keys -t "$SESS" "$1"; }
hex(){  tmux send-keys -t "$SESS" -H "$@"; }
# Human-paced typing. A zero-delay burst models a paste, not a person, and the
# plugin's throttle is keyed off measured cost.
#
# It also WAITS for the screen to catch up. A live popup costs ~35ms per
# keystroke, so the echo trails the input; returning as soon as the last byte is
# sent lets the next key land mid-line, which looks exactly like a lost
# keystroke but is not one.
# A bare ";" argument is a tmux COMMAND SEPARATOR, not a key: `send-keys -l ;`
# silently sends nothing (measured: a;b arrived as ab). Send it as hex instead.
slowtype(){ local s="$1" i k line c; for ((i=0;i<${#s};i++)); do
    c="${s:$i:1}"
    if [[ "$c" == ";" ]]; then tmux send-keys -t "$SESS" -H 3b; else tmux send-keys -t "$SESS" -l "$c"; fi
    sleep 0.12; done
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

echo "== 8b. Tab, then Enter, must actually RUN the line =="
# Regression, present in released v2.2.1: any Tab press set the
# completion-active flag, and accept-line read that as "accept the selection but
# do not execute" — so the FIRST Enter after any Tab was swallowed and the
# command just sat on the line until you pressed Enter again.
#
# Assert on the command's OUTPUT, never on the echoed line: completing
# `echo tabprobe` to `tabprobe-one` makes the shell print a line that is exactly
# `tabprobe-one`, which the prompt echo (`READY> echo tabprobe-one`) is not.
reset_line
slowtype "cd $SHORT"; sleep 0.4; key Enter; sleep 0.9
reset_line
slowtype 'echo tabprobe'; sleep 0.6
key Tab; sleep 1.0
key Enter; sleep 1.0
pane | grep -qx 'tabprobe-one' \
    && ok "one Enter after Tab ran the line" \
    || { no "Enter after Tab was swallowed (command did not run)"
         echo "    --- 8b screen ---"; pane | grep -n . | tail -8 | sed 's/^/    /'; }

echo "== 9. recent dirs: 'cd ' lists them, Tab completes the full path =="
reset_line
# Stay somewhere that contains none of the fixture names, so a completed path can
# only have come from the recent-dirs database.
slowtype "cd $SHORT"; sleep 0.4; key Enter; sleep 0.9
reset_line
slowtype 'cd '; sleep 1.5
S="$(pane)"
# An empty word after `cd ` is the one place we list on zero characters. We typed
# no directory name, so finding one on screen proves it is a candidate.
grep -qF 'proj-alpha' <<<"$S" && ok "recent dir listed on the empty word" || no "recent dir not listed on 'cd '"
grep -qF 'proj-beta'  <<<"$S" && ok "second recent dir listed"            || no "second recent dir missing"
grep -qF 'never-was'  <<<"$S" && no "non-existent entry was offered"      || ok "entry missing from disk is filtered out"

reset_line
slowtype 'cd proj-be'; sleep 0.9
# `$WORK` contains no such name, so a completed path can only come from us.
key Tab; sleep 1.0
grep -qF "$RD/proj-beta" <<<"$(pane)" \
    && ok "Tab completed the recent dir to its full path" \
    || no "Tab did not complete the recent dir"
key Enter; sleep 0.9
slowtype 'pwd'; key Enter; sleep 1.0
pane | grep -qx "$RD/proj-beta" \
    && ok "cd landed in the recent dir" \
    || no "cd did not land in the recent dir"

echo "== 10. single-column (vertical) popup layout -- OPT-IN, default off =="
# SMART_MENU_SINGLE_COLUMN=true draws ONE candidate per line instead of zsh's
# native multi-column grid. The mechanism is arithmetic: every DISPLAY string is
# padded to the full terminal width, so exactly one column fits.
#
# It is OFF by default -- the vertical list is generated rather than taken from
# compsys, so it costs descriptions / colours / fuzzy matching and falls back to
# the grid for contexts it cannot generate. So this scenario asserts three
# things in order: the default really is the grid (10a), opting in really does
# produce one per line (10b), and turning it back off really does restore the
# grid (10c). 10a and 10c are also what make 10b falsifiable -- otherwise a pass
# there could mean nothing.
#
# The pane is 140 columns and the fixture names are 7 characters, so a GRID
# would put all six on a single row while a vertical list must use six. That gap
# is what makes the row-count assertion meaningful.
SC="/tmp/zsc_e2e_sc.$$"
mkdir -p "$SC"
for n in aa bb cc dd ee ff; do : > "$SC/zscs_$n"; done
reset_line
slowtype "cd $SC"; sleep 0.4; key Enter; sleep 0.9

# --- 10a -------------------------------------------------------------------
# Nothing has been set here, so this is the SHIPPED default. If the default ever
# flips back to single-column, this fails -- which is the point: the default is
# a deliberate decision, not an accident (see lib/config.zsh).
reset_line
slowtype 'ls zscs_'; sleep 1.5
R0=$(rows_below_prompt)
if [ "$R0" -ge 1 ] && [ "$R0" -le 3 ]; then
    ok "default (opt-in off) -> candidates share a row ($R0 row(s), native grid)"
else
    no "default -> $R0 row(s); expected the native multi-column grid"
fi

echo "== 10b. opted in: SMART_MENU_SINGLE_COLUMN=true -> one candidate per line =="
send_line 'SMART_MENU_SINGLE_COLUMN=true'
reset_line
slowtype 'ls zscs_'; sleep 1.5
R=$(rows_below_prompt)
if [ "$R" -ge 6 ]; then
    ok "single column: 6 candidates occupy 6 rows"
else
    no "single column: 6 candidates occupy only $R row(s) — multi-column grid?"
    echo "    --- 10 screen ---"; pane | grep -n . | tail -12 | sed 's/^/    /'
fi
# The row count alone is not enough: a vertical list that silently dropped
# entries would satisfy it for the wrong reason.
MISS=""
for n in aa bb cc dd ee ff; do
    grep -qF "zscs_$n" <<<"$(pane)" || MISS="$MISS $n"
done
if [ -z "$MISS" ]; then
    ok "single column: all 6 candidates are listed"
else
    no "single column: candidates missing:$MISS"
fi
# A row holding two candidates IS the grid. This is the layout claim itself.
DUPES=$(pane | awk '{c=0; for(i=1;i<=NF;i++) if ($i ~ /^zscs_/) c++; if (c>=2) n++} END{print n+0}')
if [ "$DUPES" -eq 0 ]; then
    ok "single column: no row holds two candidates"
else
    no "single column: $DUPES row(s) hold two candidates (grid layout)"
fi

echo "== 10c. turned back off: SMART_MENU_SINGLE_COLUMN=false -> grid returns =="
send_line 'SMART_MENU_SINGLE_COLUMN=false'
reset_line
slowtype 'ls zscs_'; sleep 1.5
R2=$(rows_below_prompt)
if [ "$R2" -ge 1 ] && [ "$R2" -le 3 ]; then
    ok "single-column off -> candidates share a row ($R2 row(s))"
else
    no "single-column off -> $R2 row(s); expected the multi-column grid"
fi
# Back to the shipped default for whatever runs after this (which is now OFF --
# leaving it ON would silently change every later scenario's layout).
send_line 'SMART_MENU_SINGLE_COLUMN=false'
reset_line
slowtype "cd $WORK"; sleep 0.4; key Enter; sleep 0.9

echo "== 11. SMART_MENU_LISTER=fzf-tab -> we stop drawing (the 2-choose-1) =="
# Two completion listers are BOTH entitled to draw, so "two boxes at once" is
# only ever fixed by one of them stopping. That is all this switch does, and
# this is the only kind of place it can be shown: whether a list appears is a
# property of the terminal, not of any function's return value.
#
# Structured BEFORE -> OFF -> BACK ON. The step back is what makes the middle
# result mean anything: without it, "no rows" would be equally satisfied by a
# shell that had simply stopped completing.

# --- 11a: baseline, the built-in lister draws the popup ---------------------
reset_line; slowtype 'git st'; sleep 1.2
R0=$(rows_below_prompt)
[ "$R0" -ge 1 ] && ok "11a builtin lister draws a popup ($R0 rows)" \
                || no "11a baseline: no popup even before the switch ($R0 rows)"

# --- 11b: hand it over -> nothing is drawn ----------------------------------
send_line 'smart-lister fzf-tab'
# Match the OUTPUT, not the word. `grep -F 'fzf-tab'` also matches the command
# line we just typed, so on a build with no `smart-lister` at all it passed on
# the echoed input alone — the A/B run against v2.1.6 caught exactly that. The
# real CLI prints a line beginning "smart-lister: fzf-tab", which the echo of
# the typed command cannot produce.
grep -qF 'smart-lister: fzf-tab' <<<"$(pane)" && ok "11b switch reports the new owner" \
                                             || no "11b switch did not report fzf-tab"
reset_line; slowtype 'git st'; sleep 1.2
R1=$(rows_below_prompt)
if [ "$R1" -eq 0 ]; then
    ok "11b handed over -> we draw no list (0 rows)"
else
    no "11b still drew $R1 row(s) after handing the list over"
    echo "    --- 11b screen ---"; pane | grep -n . | tail -10 | sed 's/^/    /'
fi
# The inline grey suggestion is the OTHER half of this plugin and must be
# untouched by a switch that is about the candidate LIST.
if grep -qF 'git status' <<<"$(pane)"; then
    ok "11b inline suggestion still painted (only the list was handed over)"
else
    no "11b handing over the list also killed the inline suggestion"
fi
# The switch must not have disabled the FEATURE it defers to.
send_line 'smart-status'
grep -qE 'menu lister: +fzf-tab' <<<"$(pane)" \
    && ok "11b status reflects the new lister" \
    || no "11b status does not report the handed-over lister"
grep -qF 'menu (type popup): true' <<<"$(pane)" \
    && ok "11b SMART_MENU itself is untouched" \
    || no "11b handing over the list altered SMART_MENU"

# --- 11c: take it back -> the popup returns ---------------------------------
send_line 'smart-lister builtin'
reset_line; slowtype 'git st'; sleep 1.2
R2=$(rows_below_prompt)
[ "$R2" -ge 1 ] && ok "11c lister=builtin -> popup returns ($R2 rows)" \
                || no "11c popup did not come back after smart-lister builtin"

echo "== 12. the inline ghost is actually COLOURED (region_highlight survives the popup) =="
# Regression this guards. The ghost tail is painted by a region_highlight entry
# spanning POSTDISPLAY, i.e. an offset range BEYOND $#BUFFER. Two things used to
# destroy it, both measured on the previous release:
#   1. the entry was marked with a `#comment`, which zsh DROPS when it rewrites
#      the array on a redraw -- so the "remove my own entries" filter stopped
#      matching and one stale entry piled up per keystroke;
#   2. drawing the candidate list made zsh clip that entry back to the end of
#      BUFFER (`5 10` -> `5 5`, zero-length), i.e. the ghost lost its colour on
#      exactly the keystrokes that also draw the list.
# The screen is the only place this is observable: an uncoloured ghost reads as
# ordinary text, which is why the assertion is on the SGR bytes.
# 12a: at ONE character the ghost is painted but NO list is drawn. That is the
# v2.2.9 rule (the gate counts the last segment, see SMART_MENU_MIN_PREFIX):
# the popup stays away for the first keystroke of every word so typing a path
# does not repaint the screen on every character.
reset_line; slowtype 'git s'; sleep 1.0
ESC=$(printf '\033')
if pane_e | grep -qE "${ESC}\[[0-9;]*mtatus"; then
    ok "12a ghost still painted at 1 char (no hint vacuum)"
else
    no "12a ghost missing at 1 char"
fi
R=$(rows_below_prompt)
[ "$R" -eq 0 ] && ok "12a no popup at 1 char (rows=$R)" \
               || no "12a popup drawn at 1 char (rows=$R)"

# 12b: from TWO characters the list is back, together with the coloured ghost.
reset_line; slowtype 'git st'; sleep 1.0
if pane_e | grep -qE "${ESC}\[[0-9;]*mtatus"; then
    ok "12 ghost tail is rendered with a colour (SGR before 'tatus')"
else
    no "12 ghost is uncoloured (no SGR escape before the ghost tail)"
    echo "    --- 12 escaped pane (prompt line) ---"
    pane_e | grep -F 'tatus' | tail -2 | cat -v | sed 's/^/    /'
fi
# ...and the same keystroke must still show the popup: colour at the cost of the
# list would be a regression of the other half.
R=$(rows_below_prompt)
[ "$R" -ge 1 ] && ok "12b popup drawn with the coloured ghost at 2 chars ($R rows)" \
               || no "12b popup disappeared (rows=$R)"

echo "== 13. region_highlight holds exactly ONE entry of ours, spanning POSTDISPLAY =="
# The unbounded growth (1 entry per redraw) is invisible on screen, which is
# exactly why it survived: it only shows up as stale ranges and a longer array
# on every keystroke. Count our memo, and require end > start for it.
key F12; sleep 0.6
RHF="$ZD/rh.txt"
if [ -f "$RHF" ]; then
    N=$(grep -cF 'memo=zsh-smart-complete:suggestion' "$RHF")
    [ "$N" -eq 1 ] && ok "13 exactly one entry of ours ($N)" \
                   || no "13 our entries accumulated: $N (want 1)"
    OUR=$(grep -F 'memo=zsh-smart-complete:suggestion' "$RHF" | tail -1)
    S=$(echo "$OUR" | awk '{print $1}'); E=$(echo "$OUR" | awk '{print $2}')
    if [ -n "$S" ] && [ -n "$E" ] && [ "$E" -gt "$S" ]; then
        ok "13 our entry spans the ghost ($S $E, not zero-length)"
    else
        no "13 our entry is zero-length or missing: [$OUR]"
    fi
else
    no "13 no region_highlight dump (probe widget did not run)"
fi

echo "== 14. prompts still work when the script arrives on stdin (curl | bash) =="
# The documented one-liner pipes the installer into bash, which makes stdin BE
# the script. Every plain `read` then returns an empty line at once and each
# menu silently takes its default -- measured on the old installer, where the
# language and mirror prompts never waited. _tty_read must fall back to /dev/tty.
TTYH="$ZD/tty-harness.sh"
{ echo 'set -u'; echo "IFS=\$'\\n\\t'"
  sed -n '/^_tty_read() {/,/^}/p' "$REPO/install.sh"
  echo 'echo -n "pick [default=1]: "'
  echo 'ans=""; _tty_read -r ans || ans=""'
  echo 'echo "ANSWER=[$ans]"'
} > "$TTYH"
sentinel="TTYPROBE$$"
reset_line
# slowtype + echo-poll, never a fixed sleep: the plugin redraws a popup on most
# keystrokes, so the queue needs time to drain -- and `tmux send-keys` without
# -l mangles long strings (observed: the command arrived truncated). slowtype
# is character-by-character AND waits until every character is echoed.
slowtype "$(printf 'cat %s | bash; echo %s' "$TTYH" "$sentinel")"
key Enter
# It must now be WAITING (the old code had already printed its default). Poll.
# NB: the sentinel is a bad "already consumed" proof -- the TYPED COMMAND LINE
# contains it (it is echoed on screen before Enter), so a sentinel grep matches
# immediately and the wait check always fails. The observable proof that the
# prompt was consumed is the ANSWER line, so grep for that instead.
waiting=""
for _ in $(seq 1 24); do
    sleep 0.25
    if grep -qF 'pick [default=1]:' <<<"$(pane)" && ! grep -qF 'ANSWER=[' <<<"$(pane)"; then
        waiting=1; break
    fi
done
if [[ -n "$waiting" ]]; then
    ok "14 prompt blocked for input with stdin on a pipe"
    key 2; key Enter
    answered=""
    for _ in $(seq 1 16); do
        sleep 0.25
        grep -qF 'ANSWER=[2]' <<<"$(pane)" && { answered=1; break; }
    done
    [[ -n "$answered" ]] \
        && ok "14 answer came from the terminal, not the default" \
        || no "14 typed answer ignored (menu took its default)"
else
    no "14 prompt did not wait (stdin was consumed as if it were input)"
    echo "    --- 14 screen ---"; pane | grep -n . | tail -6 | sed 's/^/    /'
fi

echo "-----"
echo "E2E TOTAL PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
