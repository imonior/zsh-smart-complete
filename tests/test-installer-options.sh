#!/usr/bin/env bash
#
# tests/test-installer-options.sh
#
# Unit tests for the installer's interactive-options machinery: the managed
# OPTIONS block that turns the install-time answers into `export`s in the
# generated ~/.zshrc.
#
# WHY THIS TEST EXISTS (and why it does not run install.sh)
#   The options block has one property that is easy to break and impossible to
#   see by reading the code: POSITION. A few options — SMART_MENU_HISTORY_KEYS
#   above all — are read while the plugin installs its key bindings, so a block
#   that lands AFTER the plugin load is silently ignored. "It is in the file" is
#   not the requirement; "it is in the file *before* the plugin loads" is.
#
#   install.sh is a one-shot system installer (it edits ~/.zshrc, clones
#   plugins, installs packages), so the functions under test are EXTRACTED from
#   it and driven against throwaway files instead. The extraction is by name, so
#   the test always exercises the shipped code rather than a copy.
#
#   ./tests/test-installer-options.sh [path-to-repo]
#
set -u

REPO="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"
INSTALL="$REPO/install.sh"
TPL="$REPO/templates/zshrc.example"

[[ -f "$INSTALL" ]] || { echo "FAIL: $INSTALL missing" >&2; exit 1; }
[[ -f "$TPL" ]]     || { echo "FAIL: $TPL missing" >&2; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1" >&2; }
assert_eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got [$2] want [$3])"; fi; }
assert_has(){ if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1 (missing [$3])"; fi; }
assert_lacks(){ if grep -qF -- "$3" "$2" 2>/dev/null; then no "$1 (unexpected [$3])"; else ok "$1"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zsc_inst.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Extract the code under test, by NAME, so it can never drift from install.sh.
# A multi-line body ends with `}` in column 0; a one-line definition has to be
# matched on its own line, or `sed` runs on looking for a close that is not there.
#
# The search for that closing brace has to skip heredoc bodies, because several
# of these functions embed whole scripts -- and `_mk_dl_shim`'s embeds a
# `_zsc_rw() { … }` whose own `}` sits in column 0. Reading it with a plain
# `/^name() {/,/^}/` range returned the first 36 lines and called it the
# function, so everything the test then asserted about the rest was vacuous.
# ---------------------------------------------------------------------------
extract_fn(){
    local _ef_file="${2:-$INSTALL}"
    if grep -q "^$1() {.*}$" "$_ef_file"; then
        grep -m1 "^$1() {.*}$" "$_ef_file"
    else
        awk -v fn="$1" '
            function openheredoc(s) {
                if (!match(s, /<<[-]?[^ \t]/)) return
                s = substr(s, RSTART)
                sub(/^<<-?/, "", s)
                gsub(/[ \t].*$/, "", s)
                gsub(/["\047]/, "", s)
                if (s ~ /^[A-Za-z_][A-Za-z0-9_]*$/) { delim = s; here = 1 }
            }
            in_fn {
                if (here) {
                    print
                    if ($0 ~ "^[ \t]*" delim "[ \t]*$") here = 0
                    next
                }
                if ($0 ~ /^\}/) { print; exit }
                print
                openheredoc($0)
                next
            }
            $0 ~ "^" fn "\\(\\) \\{" { in_fn = 1; print; openheredoc($0) }
        ' "$_ef_file"
    fi
}
# The parser's own witness, before anything else leans on it: the last line of
# _mk_dl_shim is the `}` of its own wget branch, and the `chmod` that closes the
# function is present. A range that stopped at the embedded script's brace
# returns 36 lines and no chmod, which is what this catches.
if extract_fn _mk_dl_shim | grep -q 'chmod +x' \
    && [ "$(extract_fn _mk_dl_shim | wc -l | tr -d ' ')" -gt 40 ]; then
    ok "extract_fn reads past the } that closes an embedded script"
else
    no "extract_fn reads past the } that closes an embedded script" \
       "$(extract_fn _mk_dl_shim | wc -l | tr -d ' ') lines"
fi

# The answered-options defaults: the contiguous block that runs from
# ZSC_OPT_MENU to the first blank line, plus the one-line _zsc_bool that prints
# them. The end of the range is the block's own blank line rather than whatever
# definition happened to follow it, because `_zsc_bool` now lives in the shared
# core and can sit anywhere in the file.
extract_defaults(){ sed -n '/^ZSC_OPT_MENU=1/,/^$/p' "$INSTALL"; extract_fn _zsc_bool; }

# ---------------------------------------------------------------------------
# Drive the prompts from stdin, not from the terminal.
#
# The installer's prompts go through _tty_read, which re-opens /dev/tty as soon
# as stdin is not a tty — that is what makes the documented `curl … | bash`
# one-liner interactive, because there stdin IS the script. A test that feeds
# answers with a heredoc is therefore indistinguishable from that situation, and
# the real /dev/tty would block waiting for a human who is not there (measured:
# the suite hung until it was killed).
#
# So the tty layer is replaced here and the answers keep coming from stdin. The
# real behaviour — "with the script arriving on a pipe, a prompt must wait for
# the terminal and use what was typed" — cannot be asserted without a terminal
# and is covered on a real screen in tests/e2e-tmux.sh, scenario 14.
_tty_read() { read "$@" ; }

{
    extract_defaults
    # The marker constants.
    grep -E '^(ZSC|OPT)_BLOCK_(BEGIN|END)=' "$INSTALL"
    extract_fn build_smart_options
    extract_fn _upsert_options_block
} > "$TMP/lib.sh"

echo "== 0. extraction =="
for fn in build_smart_options _upsert_options_block _zsc_bool; do
    if grep -q "^$fn() {" "$TMP/lib.sh"; then ok "extracted $fn"; else no "could not extract $fn"; fi
done
if grep -q '^ZSC_OPT_MENU=1' "$TMP/lib.sh"; then ok "extracted option defaults"; else no "option defaults missing"; fi
if grep -q 'OPT_BLOCK_BEGIN=' "$TMP/lib.sh"; then ok "extracted block markers"; else no "block markers missing"; fi

# shellcheck disable=SC1090
source "$TMP/lib.sh"
source "$TMP/lib.sh"   # sourcing twice must be harmless

# ---------------------------------------------------------------------------
echo "== 1. the shipped template has the managed slot =="
# The full-stack path copies this template and relies on the markers being in
# it; without them the options would be appended at the END of the file, i.e.
# after the plugin load.
assert_has "template has the options BEGIN marker" "$TPL" "$OPT_BLOCK_BEGIN"
assert_has "template has the options END marker"   "$TPL" "$OPT_BLOCK_END"
# ...and the slot must sit above the plugin load.
tpl_opt=$(grep -nF "$OPT_BLOCK_BEGIN" "$TPL" | head -1 | cut -d: -f1)
tpl_load=$(grep -n 'zinit light imonior/zsh-smart-complete' "$TPL" | head -1 | cut -d: -f1)
if [ -n "$tpl_opt" ] && [ -n "$tpl_load" ] && [ "$tpl_opt" -lt "$tpl_load" ]; then
    ok "template: options slot is ABOVE the plugin load ($tpl_opt < $tpl_load)"
else
    no "template: options slot is not above the plugin load (opt=$tpl_opt load=$tpl_load)"
fi

# ---------------------------------------------------------------------------
echo "== 2. shipped defaults (nothing answered) =="
# These use the REAL defaults, extracted from install.sh above — never
# hand-copied here, or the test would drift from what actually ships.
# NONINTERACTIVE=1 takes exactly these.
D="$TMP/defaults.zshrc"; build_smart_options > "$D"
assert_has "default: popup on"              "$D" 'export SMART_MENU=true'
assert_has "default: single column OFF"     "$D" 'export SMART_MENU_SINGLE_COLUMN=false'
assert_has "default: recent paths on"       "$D" 'export SMART_RECENT_PATHS=true'
assert_has "default: history keys OFF"      "$D" 'export SMART_MENU_HISTORY_KEYS=false'
assert_has "default: strategy is history,completion" "$D" 'export SMART_SUGGEST_STRATEGY="history,completion"'
assert_lacks "default: no fzf-tab"          "$D" 'fzf-tab'
# WHO draws the list is written down explicitly rather than implied by the
# absence of a plugin line: the generated config has to state which lister owns
# the screen, or the "two boxes" question is left to the user to solve.
assert_has "default: built-in lister"       "$D" 'export SMART_MENU_LISTER=builtin'

echo "== 2b. every default answer agrees with lib/config.zsh =="
# The cross-check that matters. An installer default that disagrees with the
# plugin's own shipped default silently changes behaviour for everyone who
# installs non-interactively — which is how `curl | bash` and CI run. This is
# exactly the bug that once had the installer offering the Tab menu OFF while
# lib/config.zsh shipped it ON.
_cfg_default(){ zsh -f -c "source $REPO/lib/config.zsh >/dev/null 2>&1; print -r -- \${$1}"; }
assert_eq "SMART_MENU default agrees"               "$(_zsc_bool "$ZSC_OPT_MENU")"           "$(_cfg_default SMART_MENU)"
assert_eq "SMART_MENU_SINGLE_COLUMN default agrees" "$(_zsc_bool "$ZSC_OPT_SINGLE_COLUMN")"  "$(_cfg_default SMART_MENU_SINGLE_COLUMN)"
assert_eq "SMART_RECENT_PATHS default agrees"       "$(_zsc_bool "$ZSC_OPT_RECENT_PATHS")"   "$(_cfg_default SMART_RECENT_PATHS)"
assert_eq "SMART_MENU_HISTORY_KEYS default agrees"  "$(_zsc_bool "$ZSC_OPT_HISTORY_KEYS")"   "$(_cfg_default SMART_MENU_HISTORY_KEYS)"
# The lister is DERIVED (fzf-tab chosen => fzf-tab), so the derived default has
# to equal lib/config.zsh's own default or a non-interactive install would
# silently hand the screen to a lister that is not installed.
assert_eq "SMART_MENU_LISTER default agrees" \
    "$( (( ZSC_OPT_FZF_TAB )) && printf 'fzf-tab' || printf 'builtin' )" \
    "$(_cfg_default SMART_MENU_LISTER)"
assert_eq "SMART_NATIVE_MENU_SELECT default agrees" "$(_zsc_bool "$ZSC_OPT_NATIVE_MENU")"   "$(_cfg_default SMART_NATIVE_MENU_SELECT)"
assert_eq "SMART_SUGGEST_STRATEGY default agrees"   "$ZSC_OPT_STRATEGY"                      "$(_cfg_default SMART_SUGGEST_STRATEGY)"

echo "== 3. answers are honoured, including the non-default ones =="
ZSC_OPT_MENU=0; ZSC_OPT_SINGLE_COLUMN=1; ZSC_OPT_RECENT_PATHS=0
ZSC_OPT_HISTORY_KEYS=1; ZSC_OPT_NATIVE_MENU=1; ZSC_OPT_FZF_TAB=0
ZSC_OPT_STRATEGY="history,completion"
D="$TMP/answers.zshrc"; build_smart_options > "$D"
assert_has "popup off"                "$D" 'export SMART_MENU=false'
assert_has "single column opt-in honoured" "$D" 'export SMART_MENU_SINGLE_COLUMN=true'
assert_has "recent paths off"         "$D" 'export SMART_RECENT_PATHS=false'
assert_has "history keys on"          "$D" 'export SMART_MENU_HISTORY_KEYS=true'
assert_has "native Tab menu on"       "$D" 'export SMART_NATIVE_MENU_SELECT=true'
assert_has "strategy list written"    "$D" 'export SMART_SUGGEST_STRATEGY="history,completion"'
# Declining fzf-tab means the BUILT-IN list stays the owner. The switch is
# emitted either way, so "which lister" is never left ambiguous.
assert_has "fzf declined -> built-in lister" "$D" 'export SMART_MENU_LISTER=builtin'

# ---------------------------------------------------------------------------
echo "== 4. full-stack path: replaced in place, above the plugin load =="
F="$TMP/full.zshrc"
cp "$TPL" "$F"
ZSC_OPT_FZF_TAB=0; ZSC_OPT_MENU=1; ZSC_OPT_SINGLE_COLUMN=1
_upsert_options_block "$F" "$(build_smart_options)"
assert_has "options landed in the template slot" "$F" 'export SMART_MENU_SINGLE_COLUMN=true'
opt=$(grep -nF "$OPT_BLOCK_BEGIN" "$F" | head -1 | cut -d: -f1)
load=$(grep -n 'zinit light imonior/zsh-smart-complete' "$F" | head -1 | cut -d: -f1)
if [ "$opt" -lt "$load" ]; then
    ok "options block sits ABOVE the plugin load ($opt < $load)"
else
    no "options block sits BELOW the plugin load ($opt > $load) — options would be ignored"
fi
# Exactly one managed block, no matter how the template routed it.
n=$(grep -cF "$OPT_BLOCK_BEGIN" "$F")
assert_eq "exactly one managed options block" "$n" "1"

echo "== 4b. re-running is idempotent =="
cp "$F" "$TMP/first.zshrc"
ZSC_OPT_FZF_TAB=1; ZSC_OPT_STRATEGY="completion"      # change an answer
_upsert_options_block "$F" "$(build_smart_options)"
n=$(grep -cF "$OPT_BLOCK_BEGIN" "$F")
assert_eq "still exactly one block after a re-run" "$n" "1"
assert_has "re-run changed the answer" "$F" 'export SMART_SUGGEST_STRATEGY="completion"'
assert_has "re-run added fzf-tab"      "$F" 'zinit light Aloxaf/fzf-tab'
# The rest of the file must be untouched (only our block changed).
if diff <(grep -v '^export SMART_SUGGEST_STRATEGY' "$TMP/first.zshrc") \
        <(grep -v '^export SMART_SUGGEST_STRATEGY' "$F") >/dev/null; then
    ok "re-run left the rest of the file alone"
else
    # fzf-tab adds lines, so compare the parts that must not change instead.
    a=$(grep -c 'export HISTSIZE' "$F")
    assert_eq "user's own lines survive a re-run" "$a" "1"
fi
# Position must not have drifted to the end on the second pass.
opt=$(grep -nF "$OPT_BLOCK_BEGIN" "$F" | head -1 | cut -d: -f1)
load=$(grep -n 'zinit light imonior/zsh-smart-complete' "$F" | head -1 | cut -d: -f1)
if [ "$opt" -lt "$load" ]; then
    ok "re-run kept the block above the plugin load"
else
    no "re-run moved the options block below the plugin load"
fi

# ---------------------------------------------------------------------------
echo "== 5. fzf-tab is an explicit opt-in and never fights the built-in menu =="
ZSC_OPT_FZF_TAB=1; ZSC_OPT_MENU=1; ZSC_OPT_NATIVE_MENU=0; ZSC_OPT_STRATEGY="history"
build_smart_options > "$TMP/fzf.zshrc"
assert_has "fzf-tab plugin is loaded"        "$TMP/fzf.zshrc" 'zinit light Aloxaf/fzf-tab'
assert_has "fzf-tab disables the menu"       "$TMP/fzf.zshrc" "zstyle ':completion:*' menu no"
# The installer forces this off when fzf-tab is chosen (see ask_smart_options),
# so the emitted block must never claim both listers are on.
assert_has "built-in Tab menu reported off"  "$TMP/fzf.zshrc" 'export SMART_NATIVE_MENU_SELECT=false'
# ...and the list itself is handed over. Two listers both drawing IS the
# reported symptom, so choosing fzf-tab must turn ours off.
assert_has "fzf-tab chosen -> we stop listing" "$TMP/fzf.zshrc" 'export SMART_MENU_LISTER=fzf-tab'
ZSC_OPT_FZF_TAB=0
build_smart_options > "$TMP/nofzf.zshrc"
assert_lacks "fzf-tab absent when declined"  "$TMP/nofzf.zshrc" 'Aloxaf/fzf-tab'

# ---------------------------------------------------------------------------
echo "== 6. .zshrc we have never touched: appended, never inserted mid-file =="
B="$TMP/bare.zshrc"
printf '%s\n' '# my own config' 'export EDITOR=vim' > "$B"
_upsert_options_block "$B" "$(build_smart_options)"
assert_has "user's config is preserved" "$B" 'export EDITOR=vim'
assert_has "options were appended"      "$B" 'export SMART_MENU=true'
# Appended == our block comes after the user's last original line.
u=$(grep -n 'export EDITOR=vim' "$B" | cut -d: -f1)
o=$(grep -nF "$OPT_BLOCK_BEGIN" "$B" | cut -d: -f1)
if [ "$o" -gt "$u" ]; then ok "appended after the user's config"; else no "block was inserted before the user's config"; fi

# ---------------------------------------------------------------------------
echo "== 7. loader block present but no markers: inserted BEFORE the load =="
# This is the plugin-only path. The loader block is where the plugin is loaded,
# so the options must go in front of it — that is the whole point.
L="$TMP/loader.zshrc"
ZSC_BLOCK_BEGIN="# >>> zsh-smart-complete integration (managed) >>>"
ZSC_BLOCK_END="# <<< zsh-smart-complete integration <<<"
{
    printf '%s\n' '# my own config'
    printf '%s\n' "$ZSC_BLOCK_BEGIN"
    printf '%s\n' 'zinit light imonior/zsh-smart-complete'
    printf '%s\n' "$ZSC_BLOCK_END"
} > "$L"
_upsert_options_block "$L" "$(build_smart_options)"
assert_has "options block added" "$L" 'export SMART_MENU=true'
o=$(grep -nF "$OPT_BLOCK_BEGIN" "$L" | cut -d: -f1)
z=$(grep -nF "$ZSC_BLOCK_BEGIN"  "$L" | cut -d: -f1)
if [ "$o" -lt "$z" ]; then
    ok "inserted immediately before the loader block ($o < $z)"
else
    no "options landed after the loader block ($o > $z) — options would be ignored"
fi
assert_has "loader block itself is intact" "$L" 'zinit light imonior/zsh-smart-complete'

# ---------------------------------------------------------------------------
echo "== 8. the emitted block is valid, sourceable zsh =="
# A typo here would break the user's shell on every start, which is the worst
# possible failure mode for an installer.
ZSC_OPT_MENU=1; ZSC_OPT_SINGLE_COLUMN=1; ZSC_OPT_RECENT_PATHS=1
ZSC_OPT_HISTORY_KEYS=1; ZSC_OPT_NATIVE_MENU=1; ZSC_OPT_FZF_TAB=1
ZSC_OPT_STRATEGY="history,completion"
build_smart_options > "$TMP/src.zshrc"
# Strip the fzf-tab `zinit` lines: sourcing them would need a real zinit.
grep -v '^zinit ' "$TMP/src.zshrc" > "$TMP/src2.zsh"
if zsh -n "$TMP/src2.zsh" 2>"$TMP/zerr"; then
    ok "emitted block parses as zsh"
else
    no "emitted block is not valid zsh: $(head -1 "$TMP/zerr")"
fi
# And the values really do arrive as the variables they promise.
got=$(zsh -f -c "source $TMP/src2.zsh 2>/dev/null; print -r -- \$SMART_MENU_SINGLE_COLUMN/\$SMART_MENU_HISTORY_KEYS/\$SMART_SUGGEST_STRATEGY")
assert_eq "sourcing sets the documented variables" "$got" "true/true/history,completion"

# ---------------------------------------------------------------------------
echo "== 9. the Entware installer carries the same machinery =="
# Both installers are standalone files, on purpose (each is fetched on its own),
# so the shared part is generated into them from lib/install/core.sh rather than
# sourced. The generated half is checked by tools/build-installers.sh --check and
# by tests/test-installer-shared.sh; what is left to check HERE is the
# environment-specific half: that entware still asks the same questions through
# its own copies of the questionnaire and the managed block.
ENT="$REPO/install-entware.sh"
if [ -f "$ENT" ]; then
    for fn in build_smart_options _upsert_options_block ask_smart_options _zsc_bool _tty_read; do
        if grep -q "^$fn() {" "$ENT"; then ok "entware defines $fn"; else no "entware is missing $fn"; fi
    done
    assert_has "entware has the options markers" "$ENT" 'OPT_BLOCK_BEGIN="# >>> zsh-smart-complete options (managed) >>>"'
    assert_has "entware writes the options block" "$ENT" '_upsert_options_block "$ZSHRC_FILE" "$(build_smart_options)"'
    assert_has "entware asks about fzf-tab" "$ENT" "opt.fzf_tab"
    # BOTH installers route prompts through _tty_read. This used to assert the
    # opposite ("entware has no _tty_read, so a copied call would break") — that
    # assumption died with the piped installer: with `curl … | bash`, stdin IS
    # the script, so a plain `read` returns an empty line immediately and every
    # menu silently takes its default.
    assert_has "entware questionnaire reads through _tty_read" "$ENT" '_tty_read -r REPLY'
    # And its own plugin-clone helper, since _ensure_zinit_plugin is install.sh-only.
    if grep -q '^_entware_ensure_zinit_plugin() {' "$ENT"; then
        ok "entware has its own zinit plugin helper"
    else
        no "entware questionnaire would call an undefined _ensure_zinit_plugin"
    fi
else
    no "install-entware.sh is missing"
fi

# ---------------------------------------------------------------------------
echo "== 10. _scan_other_rcs: read-only advisory scan of OTHER rc files =="
# Extract the REAL function (never a copy) so the test cannot drift from what
# actually ships. It must report conflicting loaders in non-.zshrc startup
# files and NEVER edit anything.
extract_fn _scan_other_rcs > "$TMP/scan.sh"
# Stub the deps: capture what it would print, never touch a file.
_scan_caps=()
warn()    { _scan_caps+=("W:$*"); }
success() { _scan_caps+=("O:$*"); }
msg() {
    local k="$1"; shift || true
    case "$k" in
        cleanup.scan_other_rcs_line) printf '  > %s:%s' "$1" "$2" ;;
        *) printf '%s' "$k" ;;
    esac
}
# shellcheck disable=SC1090
source "$TMP/scan.sh"

# Fake home with conflicting loaders in NON-.zshrc startup files.
SH="$TMP/scanhome"; mkdir -p "$SH/conf.d" "$SH/.zshrc.d"
printf 'zinit light marlonrichert/zsh-autocomplete\n'                 > "$SH/.zprofile"
printf '# keep disabled\nzinit light zsh-users/zsh-autosuggestions\n' > "$SH/.zshenv"
# A genuine conflict loader AND a supported fzf-tab loader in the SAME file:
# only the former may be reported (fzf-tab is a supported list-drawer, not a conflict).
printf 'zinit light marlonrichert/zsh-autocomplete\nsource %s/fzf-tab.zsh\n' "$SH" > "$SH/conf.d/plugins.zsh"
printf 'echo hi\n'                                                   > "$SH/.zshrc.d/clean.zsh"
# .zshrc is owned by clean_conflict_plugin — must be ignored here (unique token).
printf 'zinit light marlonrichert/zsh-autocomplete #ZSHRCONLY\n'      > "$SH/.zshrc"
# A file with ONLY a commented loader must NOT be reported.
printf '# zinit light zsh-autocomplete\n'                              > "$SH/.zlogin"
ZDOTDIR="$SH"
_scan_caps=()
_scan_other_rcs
printf '%s\n' "${_scan_caps[@]}" > "$TMP/scan_caps"
assert_has "reports .zprofile loader"        "$TMP/scan_caps" ".zprofile"
assert_has "reports .zshenv loader"          "$TMP/scan_caps" ".zshenv"
assert_has "reports conf.d loader"           "$TMP/scan_caps" "conf.d"
assert_has "finds zsh-autocomplete"          "$TMP/scan_caps" "zsh-autocomplete"
assert_has "finds zsh-autosuggestions"       "$TMP/scan_caps" "zsh-autosuggestions"
# fzf-tab is a SUPPORTED alternative list-drawer (SMART_MENU_LISTER=fzf-tab), so
# it must NOT be reported as a conflict even though it is present in conf.d.
assert_lacks "does NOT flag fzf-tab (supported lister)"  "$TMP/scan_caps" "fzf-tab"
assert_lacks "skips the .zshrc it does not own" "$TMP/scan_caps" "ZSHRCONLY"
assert_lacks "skips file with only a commented loader" "$TMP/scan_caps" ".zlogin"
assert_lacks "skips clean .zshrc.d file"     "$TMP/scan_caps" "clean.zsh"
# Read-only: the conflicting loaders must STILL be present (not commented out).
assert_has ".zprofile left untouched"        "$SH/.zprofile" "zsh-autocomplete"
assert_has ".zshenv left untouched"          "$SH/.zshenv"    "zsh-autosuggestions"
assert_has "conf.d left untouched"           "$SH/conf.d/plugins.zsh" "fzf-tab"

# Clean case: no conflicting loaders anywhere -> success, zero warnings.
CH="$TMP/cleanhome"; mkdir -p "$CH" "$CH/conf.d"
printf 'export EDITOR=vim\n' > "$CH/.zprofile"
printf 'echo hi\n'           > "$CH/conf.d/x.zsh"
ZDOTDIR="$CH"
_scan_caps=()
_scan_other_rcs
printf '%s\n' "${_scan_caps[@]}" > "$TMP/scan_caps"
assert_lacks "clean run emits no warning"    "$TMP/scan_caps" "W:"
assert_has "clean run reports all-clear"     "$TMP/scan_caps" "O:cleanup.scan_other_rcs_clean"
# The entware installer carries the same read-only function.
if [ -f "$ENT" ] && grep -q '^_scan_other_rcs() {' "$ENT"; then
    ok "entware defines _scan_other_rcs (matches install.sh)"
else
    no "entware is missing _scan_other_rcs"
fi
if sed -n "/^_scan_other_rcs() {/,/^}/p" "$ENT" | grep -q 'pat=.*fzf-tab'; then
    no "entware _scan_other_rcs still flags fzf-tab"
else
    ok "entware _scan_other_rcs no longer flags fzf-tab"
fi

# ---------------------------------------------------------------------------
echo "== 11. clean_conflict_plugin: must NOT re-report .bak.* backups =="
# Regression: the zinit scan globs *plugin_name*, which also matched the
# `zsh-autocomplete.bak.<ts>` backup a previous run kept. Result: the installer
# claimed a conflict was still present (and offered to DELETE the user's backup)
# even when no active plugin remained. Backups are not active plugins.
extract_fn clean_conflict_plugin > "$TMP/ccp.sh"
# The messages it prints now come from the i18n table, so the table has to come
# along or every assertion below would be checking an empty string.
extract_fn _msg            >> "$TMP/ccp.sh"
extract_fn msg             >> "$TMP/ccp.sh"
LANG_CODE="${LANG_CODE:-en}"
_cc_caps=()
warn()      { _cc_caps+=("W:$*"); }
success()   { _cc_caps+=("O:$*"); }
msg()       { printf '%s' "$1"; }
prompt_yes(){ _cc_caps+=("P:$*"); return 0; }   # answer "yes" so removal path runs
comment_out_zshrc(){ _cc_caps+=("C:$*"); }
# shellcheck disable=SC1090
source "$TMP/ccp.sh"

# Isolate from the real $HOME so an actual OMZ install cannot skew the result.
_OLD_HOME="$HOME"
HOME="$TMP/cc_home"; mkdir -p "$HOME"

# --- 11a: ONLY a backup remains -> no conflict, no prompt, backup untouched.
ZP="$TMP/zp_a"; mkdir -p "$ZP/zsh-autocomplete.bak.1700000000"
ZINIT_PLUGINS_DIR="$ZP"; ZDOTDIR="$TMP/norc_a"; mkdir -p "$ZDOTDIR"
_cc_caps=()
clean_conflict_plugin "zsh-autocomplete"
printf '%s\n' "${_cc_caps[@]}" > "$TMP/cc_caps"
assert_lacks "backup alone is not reported as a conflict dir" "$TMP/cc_caps" "Found conflict plugin dir"
assert_has   "backup alone reports no conflict"               "$TMP/cc_caps" "No zsh-autocomplete conflict detected"
assert_lacks "backup alone does not prompt for removal"       "$TMP/cc_caps" "P:"
if [ -d "$ZP/zsh-autocomplete.bak.1700000000" ]; then ok "kept backup dir untouched"; else no "backup dir was removed"; fi

# --- 11b: real plugin dir + backup -> only the real one is reported/removed.
ZP="$TMP/zp_b"; mkdir -p "$ZP/zsh-autocomplete" "$ZP/zsh-autocomplete.bak.1700000000"
ZINIT_PLUGINS_DIR="$ZP"; ZDOTDIR="$TMP/norc_b"; mkdir -p "$ZDOTDIR"
_cc_caps=()
clean_conflict_plugin "zsh-autocomplete"
printf '%s\n' "${_cc_caps[@]}" > "$TMP/cc_caps"
assert_has "reports the real plugin dir" "$TMP/cc_caps" "Found conflict plugin dir"
if grep -q 'Found conflict plugin dir.*\.bak\.' "$TMP/cc_caps"; then
    no "must not report the .bak.* backup dir"
else
    ok "does not report the .bak.* backup dir"
fi
if [ -d "$ZP/zsh-autocomplete.bak.1700000000" ]; then ok "existing backup survives the run"; else no "existing backup was deleted"; fi

HOME="$_OLD_HOME"
if sed -n "/^clean_conflict_plugin() {/,/^}/p" "$ENT" | grep -q '== \*\.bak\.\*'; then
    ok "entware clean_conflict_plugin also skips .bak.* backups"
else
    no "entware clean_conflict_plugin still re-reports .bak.* backups"
fi

# ---------------------------------------------------------------------------
echo "== 12. region detection: China -> proxy/mirror, non-China -> direct =="
# The installer must NOT blanket-run the mirror speed test any more: GitHub is
# reachable directly from outside China, so only a China-region IP needs the
# proxy/mirror path. Extract the REAL mirror subsystem + region helpers.
{
    sed -n '/^MIRROR_IDS=()/,/^_add_mirror "gitclone.com"/p' "$INSTALL"
    grep -E '^(GH_MIRROR|GH_MIRROR_TYPE|MIRROR_TEST_URL|MIRROR_TEST_URL_CLONE|MIRROR_TIMES)=' "$INSTALL"
    extract_fn _mirror_label
    extract_fn _guess_mirror_type
    extract_fn _rewrite_with
    extract_fn mirror_rewrite
    extract_fn mirror_speed_test
    extract_fn mirror_ordered_indices
    extract_fn _build_mirror_pool
    extract_fn detect_public_ip_region
    extract_fn _region_display
    extract_fn _show_proxy_env
    extract_fn _test_proxy_url
    extract_fn _apply_full_proxy
    extract_fn _manual_proxy_flow
    # select_mirror's callees have to be listed here one by one, and a missing
    # one does not fail loudly: `if ! _mirror_prefix_ok "$x"` on an undefined
    # function is 127, which the `!` turns into "reject", so every manual mirror
    # below would silently come back as direct. The loop after the source checks
    # that this one is present.
    extract_fn _mirror_prefix_ok
    extract_fn select_mirror
} > "$TMP/region.sh"
# shellcheck disable=SC1090
source "$TMP/region.sh"
for fn in detect_public_ip_region select_mirror mirror_speed_test _mirror_prefix_ok; do
    if grep -q "^$fn() {" "$TMP/region.sh"; then ok "extracted $fn"; else no "could not extract $fn"; fi
done

# --- kgithub.com must be gone from the candidate list (unstable mirror domain).
if [[ " ${MIRROR_IDS[*]} " == *" kgithub.com "* ]]; then
    no "kgithub.com still present in MIRROR_IDS"
else
    ok "kgithub.com removed from MIRROR_IDS"
fi
assert_eq "candidate count is 5 (direct+3 ghproxy+gitclone)" "${#MIRROR_IDS[@]}" "5"

# --- replace the network: record URLs, feed canned responses.
# NOTE: curl runs inside `$(...)` (a subshell), so a shell-variable log would be
# lost. Record requested URLs to a FILE, which survives the subshell.
CURL_LOG_FILE="$TMP/curl_urls.log"; : > "$CURL_LOG_FILE"
MOCK_IPIP=""; MOCK_IPAPI=""; MOCK_IFCONFIG=""; MOCK_CODE="200"
curl(){
    local url="" out="" wfmt=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -o) out="$2"; shift 2 ;;
            -w) wfmt="$2"; shift 2 ;;
            -x) shift 2 ;;
            --connect-timeout|--max-time) shift 2 ;;
            -*) shift ;;
            *) url="$1"; shift ;;
        esac
    done
    printf '%s\n' "$url" >> "$CURL_LOG_FILE" 2>/dev/null || true
    case "$url" in
        *myip.ipip.net*)   [ -n "$MOCK_IPIP" ]     && printf '%s' "$MOCK_IPIP" ;;
        *ipapi.co*)        [ -n "$MOCK_IPAPI" ]    && printf '%s' "$MOCK_IPAPI" ;;
        *ifconfig.me*)     [ -n "$MOCK_IFCONFIG" ] && printf '%s' "$MOCK_IFCONFIG" ;;
        *raw.githubusercontent.com/*VERSION*|*github.com/imonior/zsh-smart-complete*)
                           [ -n "$out" ] && printf '2.2.5' > "$out"
                           [ -n "$wfmt" ] && printf "${MOCK_CODE:-200} 0.05" ;;
        *)                 [ -n "$out" ] && : > "$out"
                           [ -n "$wfmt" ] && printf '000 0.0' ;;
    esac
    return 0
}
info(){ :; }
warn(){ :; }
msg(){ local k="$1"; shift || true; printf '%s' "$k"; }

# --- 12a: a Chinese IP (ipip.net returns Chinese text) -> CN.
MOCK_IPIP="当前 IP：1.2.3.4  来自于：中国 广东 深圳 电信"
detect_public_ip_region
assert_eq "detect: country=CN"   "$_PUB_IP_COUNTRY" "CN"
assert_eq "detect: IP extracted" "$_PUB_IP"         "1.2.3.4"

# --- 12b: a non-Chinese IP -> OTHER.
MOCK_IPIP="Current IP: 5.6.7.8  from: Japan"
detect_public_ip_region
assert_eq "detect: country=OTHER" "$_PUB_IP_COUNTRY" "OTHER"

# --- 12c: ipip.net down, ipapi.co returns CN -> fallback still detects CN.
MOCK_IPIP=""; MOCK_IPAPI='{"ip":"9.9.9.9","country":"CN"}'
detect_public_ip_region
assert_eq "detect fallback: CN via ipapi" "$_PUB_IP_COUNTRY" "CN"

# --- 12d: all services down -> UNKNOWN, non-zero return.
MOCK_IPIP=""; MOCK_IPAPI=""; MOCK_IFCONFIG=""
if detect_public_ip_region; then
    no "detect returns success when all services fail"
else
    ok "detect returns failure when all services fail"
fi
assert_eq "detect: country=UNKNOWN on failure" "$_PUB_IP_COUNTRY" "UNKNOWN"

# --- 12e: NON-China -> 不再短路到直连：照样测速（direct 也在其中）。
# 直连是否更快应该测出来，而不是靠地区猜；手动输入也必须保留。
MOCK_IPIP="Current IP: 5.6.7.8  from: Japan"; MOCK_IPAPI=""; MOCK_IFCONFIG=""
GH_MIRROR=""; GH_MIRROR_TYPE="direct"; MIRROR_TIMES=(); : > "$CURL_LOG_FILE"
NONINTERACTIVE=1; SMART_INSTALL_GH_MIRROR=""; SMART_INSTALL_PROXY=""; SKIP_DEPS=0
select_mirror
if grep -q 'VERSION' "$CURL_LOG_FILE" 2>/dev/null; then
    ok "non-CN: still ran the mirror speed test (direct included)"
else
    no "non-CN: skipped the mirror speed test (region must not short-circuit)"
fi
# “仍测速”不等于“仍显示全部”：非中国区必须把预置镜像从候选池剔除，
# 既不显示、也不对它们发任何探测请求（留出它们只会误导用户选到更慢的通道）。
assert_eq "non-CN: visible pool collapses to direct only" "${#MIRROR_ACTIVE[@]}" "1"
assert_eq "non-CN: the single visible candidate is direct (index 0)" "${MIRROR_ACTIVE[0]}" "0"
if grep -qE 'ghproxy|gitclone' "$CURL_LOG_FILE" 2>/dev/null; then
    no "non-CN: probed preset China mirrors (they must be hidden)"
else
    ok "non-CN: preset China mirrors are hidden and never probed"
fi

# --- 12f: China -> select_mirror runs the speed test (proxy/mirror probe).
MOCK_IPIP="当前 IP：1.2.3.4  来自于：中国 广东 深圳 电信"; MOCK_IPAPI=""; MOCK_IFCONFIG=""
GH_MIRROR=""; GH_MIRROR_TYPE="direct"; MIRROR_TIMES=(); : > "$CURL_LOG_FILE"
NONINTERACTIVE=1; SMART_INSTALL_PROXY=""
select_mirror
if grep -q 'VERSION' "$CURL_LOG_FILE" 2>/dev/null; then
    ok "CN: ran the mirror speed test"
else
    no "CN: did not run the mirror speed test"
fi
assert_eq "CN: all candidates stay visible" "${#MIRROR_ACTIVE[@]}" "${#MIRROR_IDS[@]}"
if grep -qE 'ghproxy|gitclone' "$CURL_LOG_FILE" 2>/dev/null; then
    ok "CN: preset mirrors were probed"
else
    no "CN: preset mirrors were never probed"
fi

# --- entware carries the identical region logic.
if sed -n "/^detect_public_ip_region() {/,/^}/p" "$ENT" | grep -q 'myip.ipip.net'; then
    ok "entware defines detect_public_ip_region (matches install.sh)"
else
    no "entware is missing detect_public_ip_region"
fi
if sed -n "/^select_mirror() {/,/^}/p" "$ENT" | grep -q 'detect_public_ip_region'; then
    ok "entware select_mirror is region-aware"
else
    no "entware select_mirror is not region-aware"
fi
if grep -q 'kgithub' "$ENT"; then
    no "entware still references kgithub"
else
    ok "entware no longer references kgithub"
fi
# 两份安装器必须同步“隐藏预置镜像”这套机制，否则行为会悄悄分叉。
for f in "$INSTALL" "$ENT"; do
    b="$(basename "$f")"
    if sed -n "/^_build_mirror_pool() {/,/^}/p" "$f" | grep -q 'OTHER'; then
        ok "$b: visible pool is filtered by region"
    else
        no "$b: visible pool is NOT filtered by region (presets stay outside China)"
    fi
    if sed -n "/^select_mirror() {/,/^}/p" "$f" | grep -q '_build_mirror_pool'; then
        ok "$b: select_mirror rebuilds the visible pool"
    else
        no "$b: select_mirror never rebuilds the visible pool"
    fi
    if sed -n "/^mirror_speed_test() {/,/^}/p" "$f" | grep -q 'MIRROR_ACTIVE'; then
        ok "$b: speed test walks MIRROR_ACTIVE only"
    else
        no "$b: speed test still walks the full MIRROR_IDS"
    fi
    if sed -n "/^select_mirror() {/,/^}/p" "$f" | grep -q 'choice=\${MIRROR_ACTIVE'; then
        ok "$b: menu choice maps through MIRROR_ACTIVE"
    else
        no "$b: menu choice still indexes MIRROR_IDS directly"
    fi
done

# --- 12g: 第三种结果“没检测出来” -> 与 CN 一样全部显示、全部测速。
MOCK_IPIP=""; MOCK_IPAPI=""; MOCK_IFCONFIG=""
GH_MIRROR=""; GH_MIRROR_TYPE="direct"; MIRROR_TIMES=(); : > "$CURL_LOG_FILE"
NONINTERACTIVE=1; SMART_INSTALL_PROXY=""
select_mirror
if grep -q 'VERSION' "$CURL_LOG_FILE" 2>/dev/null; then
    ok "UNKNOWN: ran the mirror speed test (same as CN)"
else
    no "UNKNOWN: did not run the mirror speed test"
fi
assert_eq "UNKNOWN: all candidates stay visible" "${#MIRROR_ACTIVE[@]}" "${#MIRROR_IDS[@]}"
if grep -qE 'ghproxy|gitclone' "$CURL_LOG_FILE" 2>/dev/null; then
    ok "UNKNOWN: preset mirrors were probed (nothing hidden)"
else
    no "UNKNOWN: preset mirrors were never probed"
fi

# --- 12h: 交互菜单必须按“可见候选”压紧编号。
# 非中国区只剩 1 个候选，所以 2 = 手动输入镜像源、3 = 手动输入全量代理；
# 若忘了压紧编号，选 2 会落到某个已被隐藏的预置镜像上（选了像没反应）。
MOCK_CODE="200"; NONINTERACTIVE=0
MOCK_IPIP="Current IP: 5.6.7.8  from: Japan"; MOCK_IPAPI=""; MOCK_IFCONFIG=""
GH_MIRROR=""; GH_MIRROR_TYPE="direct"; MIRROR_TIMES=()
printf '2\nhttps://my.example/\n' > "$TMP/in_custom"
select_mirror < "$TMP/in_custom" > /dev/null 2>&1
assert_eq "non-CN: menu option 2 is the manual mirror entry" "$GH_MIRROR" "https://my.example/"
assert_eq "non-CN: manual mirror inferred as prefix" "$GH_MIRROR_TYPE" "prefix"

GH_MIRROR=""; GH_MIRROR_TYPE="direct"; MIRROR_TIMES=()
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
printf '3\nhttp://127.0.0.1:7890\n' > "$TMP/in_proxy"
select_mirror < "$TMP/in_proxy" > /dev/null 2>&1
assert_eq "non-CN: menu option 3 is the full-proxy entry" "$GH_MIRROR_TYPE" "proxy"
assert_eq "non-CN: full proxy exported" "${HTTPS_PROXY:-}" "http://127.0.0.1:7890"
assert_eq "non-CN: proxy does not rewrite the URL" \
    "$(_rewrite_with "$GH_MIRROR_TYPE" "$GH_MIRROR" "https://raw.githubusercontent.com/o/r/main/VERSION")" \
    "https://raw.githubusercontent.com/o/r/main/VERSION"

# --- 12i: 反向验证——CN 下预置镜像仍在，编号不压紧（2 = 第一个预置镜像）。
MOCK_IPIP="当前 IP：1.2.3.4  来自于：中国 广东 深圳 电信"
GH_MIRROR=""; GH_MIRROR_TYPE="direct"; MIRROR_TIMES=()
printf '2\n' > "$TMP/in_cn"
select_mirror < "$TMP/in_cn" > /dev/null 2>&1
assert_eq "CN: menu option 2 is still the first preset mirror" "$GH_MIRROR" "https://ghproxy.net/"
NONINTERACTIVE=1; MOCK_IPIP=""

# ---------------------------------------------------------------------------
echo "== 13. full proxy (system proxy): a second, different mechanism =="
# 镜像 = 改写 URL；全量代理 = 导出 HTTP_PROXY/HTTPS_PROXY 让 curl/git/wget 透明使用。
# 两者必须并存为菜单里的两个手动输入项。

# 先钉住“显式分支”：只验证“URL 没被改写”是不够的——就算把 proxy 分支整个删掉，
# 默认的 `*) echo "$url"` 也会让上面三条照样通过。必须确认分支真的存在，
# 否则别人日后误把 proxy 写成 prefix 式改写时，测试不会报警。
for f in "$INSTALL" "$ENT"; do
    if sed -n "/^_rewrite_with() {/,/^}/p" "$f" | grep -q '^        proxy)'; then
        ok "$(basename "$f"): _rewrite_with has an explicit proxy case"
    else
        no "$(basename "$f"): _rewrite_with is missing the explicit proxy case"
    fi
done

# --- 13a: proxy 类型绝不改写 URL（任何形态都保持原样）
assert_eq "proxy: raw URL unchanged" \
    "$(_rewrite_with proxy "http://127.0.0.1:7890" "https://raw.githubusercontent.com/o/r/main/VERSION")" \
    "https://raw.githubusercontent.com/o/r/main/VERSION"
assert_eq "proxy: releases URL unchanged" \
    "$(_rewrite_with proxy "http://127.0.0.1:7890" "https://github.com/o/r/releases/download/v1/x.tar.gz")" \
    "https://github.com/o/r/releases/download/v1/x.tar.gz"
assert_eq "proxy: git URL unchanged" \
    "$(_rewrite_with proxy "socks5://127.0.0.1:1080" "https://github.com/o/r")" \
    "https://github.com/o/r"

# --- 13b: _apply_full_proxy 导出大小写两套环境变量，并置 GH_MIRROR_TYPE=proxy
( unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
  _apply_full_proxy "http://127.0.0.1:7890"
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$HTTP_PROXY" "$HTTPS_PROXY" "$http_proxy" "$https_proxy" \
      "$ALL_PROXY" "$all_proxy" "$GH_MIRROR" "$GH_MIRROR_TYPE" ) > "$TMP/proxyenv"
assert_eq "proxy: exports both cases + sets type" "$(cat "$TMP/proxyenv")" \
    "http://127.0.0.1:7890|http://127.0.0.1:7890|http://127.0.0.1:7890|http://127.0.0.1:7890|http://127.0.0.1:7890|http://127.0.0.1:7890|http://127.0.0.1:7890|proxy"

# --- 13c: 代理可用性检测：200 才算通过
MOCK_CODE="200"
if _test_proxy_url "http://127.0.0.1:7890"; then
    ok "proxy test: reachable proxy passes"
else
    no "proxy test: reachable proxy should pass"
fi
MOCK_CODE="000"
if _test_proxy_url "http://127.0.0.1:9"; then
    no "proxy test: dead proxy should fail"
else
    ok "proxy test: dead proxy fails"
fi
MOCK_CODE="200"

# --- 13d: 菜单必须提供两个手动输入项（镜像源 / 全量代理）
# 必须查“真正调用了 _manual_proxy_flow”，而不是查 custom_proxy_d 这个变量名：
# 变量名在菜单声明处仍然存在，所以只 grep 变量名的话，把 elif 分支删掉也照样通过。
if sed -n "/^select_mirror() {/,/^}/p" "$INSTALL" | grep -q '_manual_proxy_flow'; then
    ok "menu offers a second manual entry (full proxy)"
else
    no "menu is missing the full-proxy manual entry"
fi
if sed -n "/^select_mirror() {/,/^}/p" "$ENT" | grep -q '_manual_proxy_flow'; then
    ok "entware menu offers a second manual entry"
else
    no "entware menu is missing the full-proxy manual entry"
fi
for f in "$INSTALL" "$ENT"; do
    if grep -q 'mirror.manual_proxy' "$f"; then
        ok "$(basename "$f") defines mirror.manual_proxy"
    else
        no "$(basename "$f") lacks mirror.manual_proxy"
    fi
done

# --- 13e: 预置镜像必须标注“适用于中国大陆”，direct 不得标注。
# 用真实 i18n（_msg）验证，而不是靠 mock 出来的键名。
{
    sed -n '/^MIRROR_IDS=()/,/^_add_mirror "gitclone.com"/p' "$INSTALL"
    extract_fn _mirror_label
    sed -n '/^_msg() {/,/^}/p' "$INSTALL"
    printf '%s\n' 'msg() { local key="$1"; shift || true; local t; t="$(_msg "$key")"; [[ -z "$t" ]] && t="$key"; printf "$t\n" "$@"; }'
} > "$TMP/labels.sh"
# shellcheck disable=SC1090
source "$TMP/labels.sh"
# 注意：assert_has / assert_lacks 的第二个参数是“文件路径”，不是字符串，
# 所以标签必须先落盘再断言。
LANG_CODE=zh-CN
_mirror_label 0 > "$TMP/lbl_direct"
_mirror_label 1 > "$TMP/lbl_ghproxy"
_mirror_label 4 > "$TMP/lbl_gitclone"
assert_lacks "direct label is NOT annotated" "$TMP/lbl_direct"  "适用于中国大陆"
assert_has   "ghproxy.net label annotated"   "$TMP/lbl_ghproxy" "适用于中国大陆"
assert_has   "gitclone.com label annotated"  "$TMP/lbl_gitclone" "适用于中国大陆"
LANG_CODE=en
_mirror_label 1 > "$TMP/lbl_en"
_mirror_label 0 > "$TMP/lbl_en_direct"
assert_has   "en label annotated"            "$TMP/lbl_en"        "China mainland only"
assert_lacks "en direct label NOT annotated" "$TMP/lbl_en_direct" "China mainland only"
LANG_CODE=zh-CN

# entware 的标签是硬编码中文：4 个预置镜像都要标注，direct 不得标注。
n_anno=$(grep -c '_add_mirror.*适用于中国大陆' "$ENT" || true)
assert_eq "entware: 4 preset mirrors annotated" "$n_anno" "4"
if sed -n '/^_add_mirror "direct"/p' "$ENT" | grep -q '适用于中国大陆'; then
    no "entware: direct must not be annotated"
else
    ok "entware: direct is not annotated"
fi

# ---------------------------------------------------------------------------
echo "== 14. prompts survive the documented piped one-liner (curl | bash) =="
# WHY THIS SECTION EXISTS
#   The documented install command pipes the script into bash, which makes stdin
#   BE the script. Bash reads it in chunks, so stdin is at EOF for whatever the
#   script itself runs — and every plain `read` then returns an empty line at
#   once: the language and mirror menus printed their prompt and instantly took
#   the default (observed on a real Debian host). Reads that matter must go
#   through _tty_read, which re-opens the controlling terminal.
#
#   A blanket "did the user mean to be asked?" check is impossible statically,
#   so this asserts the two things that are: no interactive read bypasses the
#   helper, and the helper itself is present in BOTH installers.
bare_reads() {
    # Interactive reads that bypass _tty_read. File loops (`while IFS= read`)
    # and the helper's own body are not prompts -- and neither is a read inside
    # a heredoc, which is a script the installer *writes out* rather than one it
    # runs (the download shim in _mk_dl_shim reads four configuration lines from
    # a file; that file is never the installer's stdin).
    awk '
      BEGIN { here = 0; delim = "" }
      /^[[:space:]]*#/ { next }
      here {
          if ($0 ~ "^[[:space:]]*" delim "[[:space:]]*$") here = 0
          next
      }
      /^_tty_read\(\) \{/ { in_tty=1; next }
      in_tty { if ($0 ~ /^\}/) in_tty=0; next }
      /while IFS= read/ { next }
      /_tty_read/ { next }
      /(^|[;&|[:space:]])read[[:space:]]+-[a-zA-Z]/ { print FNR": "$0 }
      /<<[-]?[^[:space:]]/ {
          s = $0
          sub(/^.*<<[-]?/, "", s)
          gsub(/\047/, "", s); gsub(/"/, "", s)
          if (split(s, a, /[^A-Za-z0-9_]/) >= 1 && a[1] ~ /^[A-Za-z_]/) { delim = a[1]; here = 1 }
      }
    ' "$1"
}
for f in "$INSTALL" "$ENT"; do
    n_bare=$(bare_reads "$f" | wc -l | tr -d ' ')
    if [ "$n_bare" -eq 0 ]; then
        ok "$(basename "$f"): no prompt bypasses _tty_read"
    else
        no "$(basename "$f"): $n_bare prompt(s) still read stdin directly"
        bare_reads "$f" | sed 's/^/    /' >&2
    fi
done
# The self-test of that detector: it must actually fire on a plain read.
printf 'echo -n "x: "; read -r ans\n' > "$TMP/bare-probe.sh"
[ "$(bare_reads "$TMP/bare-probe.sh" | wc -l | tr -d ' ')" -eq 1 ] \
    && ok "detector self-test: a plain read is reported" \
    || no "detector self-test: a plain read went unnoticed (assertion is vacuous)"
# ... and the other half of that self-test: the identical line inside a heredoc
# is data the installer writes, not code it runs, so it must stay quiet. Without
# this the filter above would be a way to make the check pass on anything.
{   printf 'cat > "$out" <<%sGEN%s\n' "'" "'"
    printf 'read -r inside\n'
    printf 'GEN\n'
    printf 'read -r outside\n'
} > "$TMP/bare-probe2.sh"
probe2="$(bare_reads "$TMP/bare-probe2.sh")"
[ "$(printf '%s\n' "$probe2" | grep -c .)" -eq 1 ] && printf '%s\n' "$probe2" | grep -q outside \
    && ok "detector self-test: a read inside a heredoc body is not a prompt" \
    || no "detector self-test: the heredoc filter reported [$probe2], expected only the read outside it"
# A heredoc that never terminates would hide the rest of the file, so say what
# the detector thinks about a file whose body is still open at EOF.
printf 'cat > x <<GEN\nread -r ans\n' > "$TMP/bare-probe3.sh"
[ -z "$(bare_reads "$TMP/bare-probe3.sh")" ] \
    && ok "detector self-test: an unterminated heredoc hides what follows (documented limitation)" \
    || no "detector self-test: expected the unterminated-heredoc blind spot, got [$(bare_reads "$TMP/bare-probe3.sh")]"

# An unguarded $BASH_SOURCE[0] is unset for a piped script, so `set -u` prints
# "BASH_SOURCE[0]: unbound variable" and SCRIPT_DIR silently becomes the CWD.
for f in "$INSTALL" "$ENT"; do
    assert_has "$(basename "$f"): BASH_SOURCE is guarded" "$f" 'if [[ -n "${BASH_SOURCE[0]:-}" ]]; then'
    if awk '/^SCRIPT_DIR="\$\( cd/' "$f" | grep -q .; then
        no "$(basename "$f"): unguarded SCRIPT_DIR assignment still present"
    else
        ok "$(basename "$f"): SCRIPT_DIR is only assigned behind the guard"
    fi
done

# ---------------------------------------------------------------------------
echo "== 15. the docs quote an install command that actually runs =="
# `bash -c "$(curl …)"` puts the whole script in argv; install.sh is >128 KB, so
# it dies with "argument list too long". `bash <(curl …)` works but is bash/zsh
# only. The docs therefore quote the portable pipe form everywhere — and if one
# of them is ever copy-pasted back to an older form, this fails.
for lang in "" ".zh-CN" ".zh-TW" ".ja" ".ko"; do
    RD="$REPO/README$lang.md"
    [ -f "$RD" ] || { no "README$lang.md is missing"; continue; }
    assert_has  "README$lang: quotes the pipe form"   "$RD" 'install.sh | bash'
    assert_lacks "README$lang: no bash -c \"\$(curl\"" "$RD" 'bash -c "$(curl'
    assert_lacks "README$lang: no bash <(curl"        "$RD" 'bash <(curl'
done

# ---------------------------------------------------------------------------
echo "== 16. the starship prompt template is valid TOML *and* valid starship syntax =="
# The template ships to every user and is duplicated in two places (the example
# file and install-entware.sh's heredoc), so a typo here reaches every install.
# It has already been broken twice, in two different ways, and both are pinned:
#
#   1. `[$user]($style) …` — valid TOML, and starship accepts it, but it renders
#      an EMPTY bracket: `$user` is not a top-level module name (the module is
#      `username`). The "fix" for that then produced…
#   2. `[$user] › $directory` — a BARE `[…]` group. Starship's format grammar
#      (unlike TOML) requires every `[text]` to carry a `(style)` suffix, so this
#      is a hard parse error: `Error parsing "format": --> 1:7`.
#
# So the invariant encoded here is: the top-level line names the MODULE
# (`$username`) and contains no bare `[…]` group at all.
STPL="$REPO/templates/starship.toml.example"
tpl_fmt=""
if [ -f "$STPL" ]; then
    tpl_fmt="$(sed -n '/^format = """/,/^[$]character"""/p' "$STPL" | sed -n '2p')"
    assert_eq "starship.toml.example: exact top-level format line" \
              "$tpl_fmt" '$username › $directory'
    case "$tpl_fmt" in
        *'['*) no "starship.toml.example: format has a bare '[' group (starship needs [text](style))" ;;
        *)     ok "starship.toml.example: format has no bare '[' group" ;;
    esac
    assert_lacks "starship.toml.example: no \$user module" "$STPL" '[$user]'
else
    no "templates/starship.toml.example is missing"
fi

# The entware heredoc is a second, independent copy — it must stay identical.
if [ -f "$ENT" ] && grep -q "<<'TOML'" "$ENT"; then
    sed -n "/<<'TOML'$/,/^TOML$/p" "$ENT" | sed '1d;$d' > "$TMP/starship.entware.toml"
    if [ -s "$TMP/starship.entware.toml" ]; then
        ent_fmt="$(sed -n '/^format = """/,/^[$]character"""/p' "$TMP/starship.entware.toml" | sed -n '2p')"
        assert_eq "entware heredoc: same format line as the example" "$ent_fmt" "$tpl_fmt"
    else
        no "entware heredoc: could not extract the starship TOML"
    fi
else
    no "install-entware.sh: starship TOML heredoc not found"
fi

# TOML validity first (the heredoc must actually load), then — where the real
# binary is present — a real render, because only starship itself can tell a
# valid-TOML-but-invalid-format string from a good one.
if command -v python3 >/dev/null 2>&1 && [ -s "$TMP/starship.entware.toml" ]; then
    if python3 - "$STPL" "$TMP/starship.entware.toml" 2>"$TMP/py.err" <<'PY'
import sys, tomllib
for p in sys.argv[1:]:
    with open(p, "rb") as fh:
        fmt = tomllib.load(fh)["format"].strip()
    assert fmt == "$username \u203a $directory\n$character", (p, fmt)
PY
    then ok "both starship templates load as TOML with the expected format"
    else no "a starship template is not valid TOML / has the wrong format: $(head -1 "$TMP/py.err")"
    fi
else
    ok "python3 unavailable - skipped the TOML load check"
fi

if command -v starship >/dev/null 2>&1 && [ -f "$STPL" ]; then
    if STARSHIP_CONFIG="$STPL" starship prompt 2>&1 | grep -q 'Error parsing'; then
        no "starship rejects the shipped template ('Error parsing')"
    else
        ok "starship renders the shipped template without a parse error"
    fi
else
    ok "starship unavailable - skipped the render check"
fi

# ---------------------------------------------------------------------------
echo "== 17. atuin: NOBIND by default - the floating TUI is a second UI =="
# User report against v2.2.6: with everything at its default, TWO dynamic
# hints appeared - the plugin's popup AND atuin's floating search TUI
# (Ctrl-R / ? bound by the template's unconditional atuin init). The plugin
# reads atuin's SQLite history DB directly, so the bindings are pure loss;
# they are now an installer question (default no) and the generated config
# uses ATUIN_NOBIND, which keeps history recording but binds nothing.
{
    extract_defaults
    grep -E '^(ZSC|OPT)_BLOCK_(BEGIN|END)=' "$INSTALL"
    extract_fn build_zsc_integration
    extract_fn _scan_foreign_atuin
} > "$TMP/lib17.sh"
# shellcheck disable=SC1090
source "$TMP/lib17.sh"

ZSC_VIMODE_SNIPPET=""
PROMPT_INIT_SNIPPET='command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"
command -v zoxide   >/dev/null 2>&1 && eval "$(zoxide init zsh)"'

ZSC_OPT_ATUIN_BIND=0; ZSC_OPT_VIMODE=0
D17a="$TMP/atuin-default.zshrc"; build_zsc_integration > "$D17a"
assert_has  "17 default: NOBIND init written"        "$D17a" 'ATUIN_NOBIND="true" eval "$(atuin init zsh)"'
assert_lacks "17 default: no TUI binding (--disable-up-arrow)" "$D17a" '--disable-up-arrow'
if grep -qE '^[[:space:]]*bindkey ' "$D17a"; then no "17 default: a live bindkey line exists"; else ok "17 default: no key bound by us (comments only)"; fi

ZSC_OPT_ATUIN_BIND=1
D17b="$TMP/atuin-optin.zshrc"; build_zsc_integration > "$D17b"
assert_has  "17 opt-in: TUI init written"            "$D17b" 'eval "$(atuin init zsh --disable-up-arrow)"'
assert_lacks "17 opt-in: NOBIND not used"            "$D17b" 'ATUIN_NOBIND'
ZSC_OPT_ATUIN_BIND=0

# the question exists: one case label in _msg + one call site. The five
# language variants live INSIDE the case body and are covered by the render
# check further down in this suite's language sweep.
n_lang=$(grep -cF 'opt.atuin_bind)' "$INSTALL")
assert_eq "17 question defined + asked" "$n_lang" "2"
n_call=$(grep -cF 'msg opt.atuin_bind' "$INSTALL")
assert_eq "17 question is asked exactly once" "$n_call" "1"
# and no unconditional binding may remain anywhere in the shipped config
assert_lacks "17 combo snippet: no unconditional atuin init" "$INSTALL" 'command -v atuin    >/dev/null 2>&1 && eval'
assert_has  "17 template: NOBIND form"        "$TPL" 'ATUIN_NOBIND="true" eval "$(atuin init zsh)"'
assert_lacks "17 template: no TUI binding"    "$TPL" '--disable-up-arrow'

# functional: a FOREIGN atuin init line (outside the managed block) is
# reported read-only; the line inside the managed block is not.
warn(){ printf 'WARN:%s\n' "$*"; }
msg(){ printf '%s' "$1"; }
FB="$TMP/fakehome"; mkdir -p "$FB"
cat > "$FB/.zshrc" <<'FZ'
# a user's own older line, outside our block:
eval "$(atuin init zsh)"
# >>> zsh-smart-complete integration (managed) >>>
command -v atuin >/dev/null 2>&1 && ATUIN_NOBIND="true" eval "$(atuin init zsh)"
# <<< zsh-smart-complete integration <<<
FZ
n_warn=$(HOME="$FB" ZDOTDIR="$FB" _scan_foreign_atuin 2>&1 | grep -c '^WARN:')
# head + line + hint = 3 warns for exactly one foreign line; the managed
# block's own NOBIND line must contribute none.
assert_eq "17 foreign scan: head+line+hint, managed block excluded" "$n_warn" "3"

# ---------------------------------------------------------------------------
echo "== 18. language menu uses endonyms, not an English fallback =="
# Regression guard: select_language once rendered the five options through
# `msg lang.option_*`, which follows LANG_CODE and falls back to English at the
# default (en). A user who cannot read English could then not pick their own
# language. The menu must always show each language in its own script (endonym)
# so every reader recognises their entry without knowing English.
extract_fn select_language > "$TMP/lang_menu.sh"
assert_has  "18 menu: default entry is English"              "$TMP/lang_menu.sh" '1 "English"'
assert_has  "18 menu: Simplified Chinese in Chinese"         "$TMP/lang_menu.sh" '2 "简体中文"'
assert_has  "18 menu: Traditional Chinese in Chinese"        "$TMP/lang_menu.sh" '3 "繁體中文"'
assert_has  "18 menu: Japanese in Japanese"                  "$TMP/lang_menu.sh" '4 "日本語"'
assert_has  "18 menu: Korean in Korean"                      "$TMP/lang_menu.sh" '5 "한국어"'
assert_lacks "18 menu: no English-fallback option rendering" "$TMP/lang_menu.sh" '$(msg lang.option'
# the two installer copies must not drift on the menu: install-entware.sh has
# always hard-coded the endonyms, so install.sh must print the same lines.
ENTWARE="$REPO/install-entware.sh"
sed -n '/^select_language() {/,/^}/p' "$ENTWARE" > "$TMP/lang_menu_ent.sh"
if diff -q <(grep -E 'printf "  %d\) %s' "$TMP/lang_menu.sh") <(grep -E 'printf "  %d\) %s' "$TMP/lang_menu_ent.sh") >/dev/null 2>&1; then
    ok "18 menu: both installers print the same endonym menu"
else
    no "18 menu: both installers print the same endonym menu"
fi

# ---------------------------------------------------------------------------
echo "== 19. install.sh FALLBACK starship template is byte-identical =="
# Regression guard: curl|bash installs have no templates/ directory, so
# resolve_template writes its embedded FALLBACK heredoc. That copy had drifted
# to a stale minimal config (plain ❯ prompt), so online installs never got the
# recommended "username › directory / :>" prompt — the file on disk looked
# right, the installed one was wrong. The FALLBACK must stay byte-identical to
# templates/starship.toml.example.
FB_STAR="$(sed -n '/starship\.toml\.example)/,/^FALLBACK$/p' "$REPO/install.sh" \
    | sed -e '1,/<<'"'"'FALLBACK'"'"'$/d' -e '/^FALLBACK$/d')"
printf '%s\n' "$FB_STAR" > "$TMP/starship.fallback.toml"
if [ -s "$TMP/starship.fallback.toml" ]; then
    if diff -q "$STPL" "$TMP/starship.fallback.toml" >/dev/null 2>&1; then
        ok "19 fallback: install.sh embedded starship template is byte-identical"
    else
        no "19 fallback: install.sh embedded starship template is byte-identical"
    fi
    fb_fmt="$(sed -n '/^format = """/,/^[$]character"""/p' "$TMP/starship.fallback.toml" | sed -n '2p')"
    assert_eq "19 fallback: same format line as the example" "$fb_fmt" "$tpl_fmt"
else
    no "19 fallback: could not extract the FALLBACK starship heredoc from install.sh"
fi

# ---------------------------------------------------------------------------
echo "== 20. starship config classification (legacy -> repair) =="
# Regression guard: users who installed before v2.2.9 already HAVE a
# ~/.config/starship.toml — the one written by the stale FALLBACK, which has no
# `format` key and therefore renders Starship's own DEFAULT prompt. The old code
# only asked a question there, so re-running the installer could not fix it. The
# classification below is what decides repair vs. ask, and it is extracted by
# name so it always exercises shipped code.
eval "$(extract_fn _starship_cfg_is_recommended)" || echo "cannot extract _starship_cfg_is_recommended"
eval "$(extract_fn _starship_cfg_has_layout)"     || echo "cannot extract _starship_cfg_has_layout"
eval "$(extract_fn _starship_cfg_decide)"         || echo "cannot extract _starship_cfg_decide"

LEGACY="$TMP/starship.legacy.toml"
cat > "$LEGACY" <<'TOML'
add_newline = false
[line_break]
disabled = true
[character]
success_symbol = "[❯](bold green)"
error_symbol   = "[❯](bold red)"
[directory]
truncation_length = 3
style = "bold cyan"
TOML
RECO="$TMP/starship.recommended.toml"; cp "$STPL" "$RECO"
CUSTOM="$TMP/starship.custom.toml";    printf '%s\n' 'format = "$all"' > "$CUSTOM"
MISSING="$TMP/starship.missing.toml"
COMMENTS="$TMP/starship.comments.toml"; printf '%s\n' '# my own notes' 'add_newline = false' > "$COMMENTS"

assert_eq "20 decide: absent file -> missing"      "$(_starship_cfg_decide "$MISSING")"   "missing"
assert_eq "20 decide: v2.2.8 generated -> legacy"  "$(_starship_cfg_decide "$LEGACY")"    "legacy"
assert_eq "20 decide: no layout at all -> legacy"  "$(_starship_cfg_decide "$COMMENTS")"  "legacy"
assert_eq "20 decide: recommended file -> keep"    "$(_starship_cfg_decide "$RECO")"      "recommended"
assert_eq "20 decide: custom layout -> custom"     "$(_starship_cfg_decide "$CUSTOM")"    "custom"
# The two-line layout is what the repair installs; make sure the "leave it
# alone" test really rests on that content and not on the filename.
_got="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$RECO" | grep -cF 'success_symbol = "[:> ](bold green)"')"
assert_eq "20 decide: recommended marker present in the template" "$_got" "1"

# ---------------------------------------------------------------------------
echo "== 21. install-entware.sh writes the SAME recommended template =="
# Same drift class as install.sh, same fix: the embedded heredoc is the only
# source a curl|bash install can reach. It is now owned by one function,
# _write_recommended_starship, so there is exactly one copy to keep honest.
EW="$REPO/install-entware.sh"
EW_STAR="$TMP/starship.entware.toml"
if [ -f "$EW" ]; then
    sed -n "/^_write_recommended_starship() {/,/^}/p" "$EW" \
        | sed -e "1,/<<'TOML'\$/d" -e '/^TOML$/d' -e '/^}$/d' > "$EW_STAR"
    if [ -s "$EW_STAR" ] && diff -q "$STPL" "$EW_STAR" >/dev/null 2>&1; then
        ok "21 entware: embedded starship template is byte-identical"
    else
        no "21 entware: embedded starship template is byte-identical"
    fi
    _ew_count="$(grep -c "^_write_recommended_starship() {" "$EW")"
    assert_eq "21 entware: exactly one copy of the writer function" "$_ew_count" "1"
    assert_has "21 entware: starship writes go through the classification" "$EW" '_starship_cfg_decide'
    if grep -q "STARSHIP_CONFIG_FILE) == """ "$EW"; then
        no "21 entware: no stale file-exists test left behind"
    else
        ok "21 entware: no stale file-exists test left behind"
    fi
else
    no "21 entware: $EW missing"
fi

# ---------------------------------------------------------------------------
echo "== 22. no hardcoded output strings left in either installer =="
# Regression guard for the i18n sweep: every user-visible line must come from
# the msg table. Two independent checks per installer:
#   * no `info/warn/error/success/prompt_yes "<literal text>"` call is left
#     (a translated one always reads `... "$(msg key ...)"`), and
#   * every key referenced as `$(msg KEY ...)` is actually defined in that
#     installer's _msg table (a typo there silently prints the key name).
for _f in "$INSTALL" "$EW"; do
    _name="$(basename "$_f")"
    _hard="$(grep -nE '(info|warn|error|success|prompt_yes) "[^"]*[A-Za-z]{3,}[^"]*"' "$_f" \
        | grep -v 'msg ' | grep -v '^[0-9]*:[[:space:]]*#' | wc -l | tr -d ' ')"
    assert_eq "22 i18n: $_name has no hardcoded output text" "$_hard" "0"
    _undef=0
    for _k in $(grep -oE '\$\(msg [A-Za-z_][A-Za-z_.0-9]*' "$_f" \
                | sed 's/.*msg //' | sort -u); do
        # escape the dots: a key is a case-branch label, so match it literally
        _esc="$(printf '%s' "$_k" | sed 's/\./\\./g')"
        grep -qE "^[[:space:]]+${_esc}\)$" "$_f" || _undef=$((_undef+1))
    done
    assert_eq "22 i18n: every msg key used by $_name is defined" "$_undef" "0"
done

# ---------------------------------------------------------------------------
echo "== 23. _upsert_options_block: every placement branch, in BOTH installers =="
# install-entware.sh once called _upsert_options_block with ZSC_BLOCK_BEGIN
# never defined in that file (install.sh had always defined it). The empty
# variable made `grep -qF ""` match EVERY file, so the branch "insert above
# the loader block" was always chosen — and its awk inserts before the first
# EMPTY LINE, of which the Phase-4 freshly-created .zshrc has none (nor any
# marker, nor any plugin mention yet, because the loader is appended AFTER
# this call). Net effect: the options block was silently never written, so a
# curl|bash install on a clean machine ignored every interactive answer.
#
# So the SHIPPED function is extracted from EACH installer and driven against
# one fixture per branch. The marker variables are reset to empty before each
# load, which reproduces the old failure mode faithfully instead of tripping
# `set -u` here.
_pos(){ grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }   # first line number of a fixed string

for _inst in "$INSTALL" "$EW"; do
    _nm="$(basename "$_inst")"

    # Static form of the same bug: calling the function with a marker the
    # file never defines. Four definitions, not three, is the contract.
    _defs="$(grep -cE '^(ZSC|OPT)_BLOCK_(BEGIN|END)=' "$_inst")"
    assert_eq "23 $_nm: all four block markers are defined" "$_defs" "4"

    ZSC_BLOCK_BEGIN=""; ZSC_BLOCK_END=""; OPT_BLOCK_BEGIN=""; OPT_BLOCK_END=""
    eval "$(grep -E '^(ZSC|OPT)_BLOCK_(BEGIN|END)=' "$_inst")"
    eval "$(sed -n '/^_upsert_options_block() {/,/^}/p' "$_inst")"

    _blk="${OPT_BLOCK_BEGIN}
export SMART_TEST_NEW=1
${OPT_BLOCK_END}"
    f="$TMP/23.block"

    # -- branch 1: markers present -> replace in place, same position -------
    printf '%s\n' "top line" "$OPT_BLOCK_BEGIN" "export STALE=1" "$OPT_BLOCK_END" "bottom line" > "$f"
    _upsert_options_block "$f" "$_blk"
    assert_lacks "23 $_nm f1: old managed block replaced" "$f" "export STALE=1"
    assert_has   "23 $_nm f1: new managed block written"  "$f" "export SMART_TEST_NEW=1"
    assert_eq    "23 $_nm f1: still exactly one managed block" "$(grep -cF "$OPT_BLOCK_BEGIN" "$f")" "1"
    _b=$(_pos "$f" "$OPT_BLOCK_BEGIN"); _b=${_b:-99999}
    _e=$(_pos "$f" "$OPT_BLOCK_END");   _e=${_e:-99999}
    _t=$(_pos "$f" "top line");         _t=${_t:-99999}
    _ot=$(_pos "$f" "bottom line");     _ot=${_ot:-99999}
    if [ "$_t" -lt "$_b" ] && [ "$_e" -lt "$_ot" ]; then
        ok "23 $_nm f1: replacement kept the original position"
    else
        no "23 $_nm f1: replacement kept the original position (top=$_t begin=$_b end=$_e bottom=$_ot)"
    fi

    # -- branch 2: no options markers, loader markers present -> above them --
    # No blank lines on purpose: with an empty ZSC_BLOCK_BEGIN this is the
    # exact shape the old bug swallowed.
    printf '%s\n' "hist stuff" "$ZSC_BLOCK_BEGIN" "zinit light imonior/zsh-smart-complete" "last line" > "$f"
    _upsert_options_block "$f" "$_blk"
    assert_has "23 $_nm f2: options block inserted" "$f" "$OPT_BLOCK_BEGIN"
    _b=$(_pos "$f" "$OPT_BLOCK_BEGIN"); _b=${_b:-99999}
    _zs=$(_pos "$f" "$ZSC_BLOCK_BEGIN"); _zs=${_zs:-0}
    if [ "$_b" -lt "$_zs" ]; then
        ok "23 $_nm f2: options sit ABOVE the loader block ($_b < $_zs)"
    else
        no "23 $_nm f2: options sit ABOVE the loader block ($_b < $_zs)"
    fi

    # -- branch 3: no markers at all, but the plugin is mentioned -----------
    printf '%s\n' "# personal setup" 'source ~/.zsh/zsh-smart-complete/zsh-smart-complete.plugin.zsh' "alias ll='ls -l'" > "$f"
    _upsert_options_block "$f" "$_blk"
    assert_has "23 $_nm f3: options block inserted" "$f" "$OPT_BLOCK_BEGIN"
    _e=$(_pos "$f" "$OPT_BLOCK_END");    _e=${_e:-99999}
    _m=$(_pos "$f" "zsh-smart-complete.plugin.zsh"); _m=${_m:-0}
    if [ "$_e" -lt "$_m" ]; then
        ok "23 $_nm f3: options precede the unmarked plugin reference ($_e < $_m)"
    else
        no "23 $_nm f3: options precede the unmarked plugin reference ($_e < $_m)"
    fi

    # -- branch 4: untouched file -> append. THIS is the regression fixture:
    # no markers, no plugin mention and NOT ONE empty line, exactly like the
    # .zshrc entware's Phase 4 creates before appending the loader.
    printf '%s\n' 'export HISTFILE="$HOME/.zsh_history"' 'setopt appendhistory sharehistory' > "$f"
    _upsert_options_block "$f" "$_blk"
    assert_has "23 $_nm f4: options written to a marker-free, blank-line-free file" "$f" "$OPT_BLOCK_BEGIN"
    assert_eq  "23 $_nm f4: original content stays on top" "$(head -1 "$f")" 'export HISTFILE="$HOME/.zsh_history"'
    assert_eq  "23 $_nm f4: file ends with the managed block" "$(tail -1 "$f")" "$OPT_BLOCK_END"
done

# The two installers must not drift apart on the shared contract: same marker
# strings, same placement function.
if diff <(grep -E '^(ZSC|OPT)_BLOCK_(BEGIN|END)=' "$INSTALL") \
        <(grep -E '^(ZSC|OPT)_BLOCK_(BEGIN|END)=' "$EW") >/dev/null 2>&1; then
    ok "23 both installers define identical block markers"
else
    no "23 both installers define identical block markers"
fi
if diff <(sed -n '/^_upsert_options_block() {/,/^}/p' "$INSTALL") \
        <(sed -n '/^_upsert_options_block() {/,/^}/p' "$EW") >/dev/null 2>&1; then
    ok "23 both installers ship the same _upsert_options_block"
else
    no "23 both installers ship the same _upsert_options_block"
fi

# ---------------------------------------------------------------------------
echo "== 24. _run_remote_script: fetch, look, then run =="
# `curl … | sh` gave the shell whatever arrived. A connection that dies halfway
# ran the first half; a mirror answering 200 with a portal page ran HTML; and
# because run_with_mirror_dl evaluates its command a second time as the direct
# fallback, a half-executed third-party installer could run twice. The helper
# under test is what replaced that, so this drives it against a fake `curl`.
{
    sed -n '/^ZSC_OPT_MENU=1/,/^$/p' "$INSTALL"
    grep -E '^(ZSC|OPT)_BLOCK_(BEGIN|END)=' "$INSTALL"
    for fn in _rewrite_with mirror_rewrite curl_get _run_remote_script \
              info success warn error msg _msg; do
        extract_fn "$fn"
    done
} > "$TMP/lib24.sh"
# shellcheck disable=SC1090
source "$TMP/lib24.sh"

mkdir -p "$TMP/bin24"
cat > "$TMP/bin24/curl" <<'STUB'
#!/usr/bin/env bash
# Logs its argv, then serves $FAKE_BODY as the body of the request.
printf 'curl %s\n' "$*" >> "$FAKE_LOG"
out=""
while [ $# -gt 0 ]; do
    [ "$1" = "-o" ] && { out="$2"; shift 2; continue; }
    shift
done
[ -n "$out" ] && cp -- "$FAKE_BODY" "$out"
exit "${FAKE_RC:-0}"
STUB
chmod +x "$TMP/bin24/curl"

# A body long enough to clear the size floor, and which proves it ran by
# recording the arguments it was given.
_good_body() {
    {   printf '#!/bin/sh\n'
        printf '# %s\n' "$(head -c 500 /dev/zero | tr '\0' 'x')"
        printf 'printf "%%s\\n" "$@" > "%s/argv24"\n' "$TMP"
        printf 'touch "%s/ran24"\n' "$TMP"
    } > "$TMP/body24"
}
_html_body() {
    {   printf '<!DOCTYPE html>\n<html>\n<head><title>Sign in</title></head>\n'
        printf '<body>%s</body>\n' "$(head -c 900 /dev/zero | tr '\0' 'y')"
        printf '</html>\n'
    } > "$TMP/body24"
}

PATH="$TMP/bin24:$PATH"
# An earlier section defines a `curl()` stub, and in bash a function wins over
# PATH — the fake below would never be reached.
unset -f curl 2>/dev/null || true
export FAKE_LOG="$TMP/curl24.log"; : > "$FAKE_LOG"
export FAKE_BODY="$TMP/body24"
GH_MIRROR=""; GH_MIRROR_TYPE=direct; LANG_CODE=en

# Run in a subshell with TMPDIR pointed at $TMP, so the fetched file itself is
# observable: it must be gone afterwards whatever the outcome.
_run24() { ( TMPDIR="$TMP" _run_remote_script "$@" ) > "$TMP/out24" 2>&1; }
_leftovers() { find "$TMP" -maxdepth 1 -name 'zsc-remote.*' 2>/dev/null | wc -l | tr -d ' '; }

rm -f -- "$TMP/ran24" "$TMP/argv24"; : > "$FAKE_LOG"
_good_body; export FAKE_RC=0
_run24 https://starship.example/install.sh -y; rc=$?
# Every refusal below is also what an unfound stub produces, so prove the stub
# is the thing that answered before trusting any of them.
assert_eq "24 the fake curl was reached (nothing below is vacuous)" "$(wc -l < "$FAKE_LOG" | tr -d ' ')" "1"
assert_eq "24 a whole script runs, and runs with the caller's arguments" "$rc" "0"
[ -f "$TMP/ran24" ] && ok "24 the fetched script was executed" || no "24 the fetched script was executed"
assert_has "24 the argument reached the script" "$TMP/argv24" "-y"
assert_eq "24 the downloaded file is cleaned up after a success" "$(_leftovers)" "0"

rm -f -- "$TMP/ran24"
_html_body
_run24 https://portal.example/; rc=$?
[ "$rc" -ne 0 ] && ok "24 an HTML page is refused (exit $rc)" || no "24 an HTML page is refused"
[ ! -f "$TMP/ran24" ] && ok "24 nothing ran when the body was a web page" || no "24 nothing ran when the body was a web page"
grep -qiE 'html|script' "$TMP/out24" \
    && ok "24 the refusal says why" || no "24 the refusal says why" "$(cat "$TMP/out24")"
assert_eq "24 the downloaded file is cleaned up after a refusal" "$(_leftovers)" "0"

# A body under the floor is what a half-open connection looks like from the
# receiving end, which is the case `curl | sh` executed anyway.
printf '#!/bin/sh\nexit 0\n' > "$TMP/body24"
rm -f -- "$TMP/ran24"
_run24 https://starship.example/install.sh; rc=$?
[ "$rc" -ne 0 ] && ok "24 a truncated body is refused (exit $rc)" || no "24 a truncated body is refused"
[ ! -f "$TMP/ran24" ] && ok "24 a truncated body never runs" || no "24 a truncated body never runs"

: > "$FAKE_LOG"; _good_body; export FAKE_RC=22
_run24 https://starship.example/install.sh; rc=$?
assert_eq "24 curl's own failure is the exit code, not a reinterpreted one" "$rc" "22"
assert_eq "24 a failed fetch does not reach the size check" "$(wc -l < "$FAKE_LOG" | tr -d ' ')" "1"

# The one property the rewrite of _ensure_omz depends on: mirror_rewrite is
# applied exactly once. A double rewrite would prepend the prefix twice and
# still "work" in every test that does not look at the URL.
: > "$FAKE_LOG"; GH_MIRROR="https://gh.example/"; GH_MIRROR_TYPE=prefix
_run24 https://github.com/ohmyzsh/ohmyzsh/master/tools/install.sh --unattended
if grep -qF -- 'https://gh.example/https://github.com/ohmyzsh' "$FAKE_LOG"; then
    ok "24 the mirror prefix is applied"
else
    no "24 the mirror prefix is applied" "$(cat "$FAKE_LOG")"
fi
if grep -qF -- 'https://gh.example/https://gh.example/' "$FAKE_LOG"; then
    no "24 the mirror prefix is applied exactly once" "$(cat "$FAKE_LOG")"
else
    ok "24 the mirror prefix is applied exactly once"
fi
GH_MIRROR=""; GH_MIRROR_TYPE=direct

# The helper is shared code, so the artifact that was not edited by hand has to
# carry the same body — this is the check that would catch a regenerated file
# that lost it, which the byte-comparison suite only covers while both sides
# agree with the core.
if diff <(extract_fn _run_remote_script) <(extract_fn _run_remote_script "$EW") >/dev/null 2>&1; then
    ok "24 both installers ship the same _run_remote_script"
else
    no "24 both installers ship the same _run_remote_script"
fi

# ---------------------------------------------------------------------------
echo "== 25. a half-finished config rewrite is undone =="
# Every write below is a rename, so no single one can leave a truncated file --
# but the installer performs them as a SEQUENCE on $ZSHRC_FILE, and an abort
# between two of them leaves a .zshrc that parses, starts a shell, and does not
# load the plugin. The .bak.<timestamp> sitting next to it does not undo that:
# nothing points at it, and the run that made it has already stopped.
{
    for fn in _guard_config_write _undo_config_write _release_config_write_guard; do
        extract_fn "$fn"
    done
} > "$TMP/lib25.sh"
# shellcheck disable=SC1090
source "$TMP/lib25.sh"

RC25="$TMP/rc25"
LANG_CODE=en
# The snapshot has to be observable, so it is parked in $TMP like the fetch.
_snap_count() { find "$TMP" -maxdepth 1 -name 'zsc-guard.*' 2>/dev/null | wc -l | tr -d ' '; }

# 1. A pre-existing config comes back byte for byte.
printf 'OLD\n' > "$RC25"
( TMPDIR="$TMP" _guard_config_write "$RC25"
  printf 'NEW\n' > "$RC25"
  exit 1 ) > "$TMP/out25a" 2>&1
assert_eq "25 an abort partway through restores the pre-install content" "$(cat "$RC25")" "OLD"
assert_has "25 the rollback is announced" "$TMP/out25a" "restored"

# The witness for everything below: without the guard the same run leaves the
# half-installed file, so a pass above cannot be the file never having changed.
printf 'OLD\n' > "$RC25"
( printf 'NEW\n' > "$RC25"; exit 1 ) >/dev/null 2>&1
assert_eq "25 without the guard the half-write is what survives" "$(cat "$RC25")" "NEW"

# 2. "There was no .zshrc before" is a state too. The installer has a branch
# that creates the file, and leaving that file behind would claim an install
# that never happened.
rm -f -- "$RC25"
( TMPDIR="$TMP" _guard_config_write "$RC25"
  printf 'NEW\n' > "$RC25"
  exit 1 ) > "$TMP/out25b" 2>&1
[ ! -e "$RC25" ] && ok "25 a .zshrc the install created is removed again" \
                  || no "25 a .zshrc the install created is removed again" "left: $(cat "$RC25")"

# 3. Success is not a failure: the config the user asked for stays.
printf 'OLD\n' > "$RC25"
( TMPDIR="$TMP" _guard_config_write "$RC25"
  printf 'NEW\n' > "$RC25"
  exit 0 ) >/dev/null 2>&1
assert_eq "25 a finished install keeps what it wrote" "$(cat "$RC25")" "NEW"

# 4. Released: a failure after the last write must not talk the installer out
# of a config the user asked for.
printf 'OLD\n' > "$RC25"
( TMPDIR="$TMP" _guard_config_write "$RC25"
  printf 'NEW\n' > "$RC25"
  _release_config_write_guard
  exit 1 ) >/dev/null 2>&1
assert_eq "25 releasing the guard keeps the config through a later failure" "$(cat "$RC25")" "NEW"

# 5. The snapshot really exists while armed (otherwise 1-4 would pass on a
# guard that quietly did nothing) and really gone once the run ends.
printf 'OLD\n' > "$RC25"
( TMPDIR="$TMP" _guard_config_write "$RC25"
  _snap_count > "$TMP/during25"
  printf 'NEW\n' > "$RC25"
  exit 1 ) >/dev/null 2>&1
assert_eq "25 arming the guard takes a snapshot" "$(cat "$TMP/during25")" "1"
assert_eq "25 and no snapshot is left behind" "$(_snap_count)" "0"

# 6. Nothing on the rollback path may be an unbound variable: these installers
# run under `set -u`, and a trap that dies is worse than no trap.
( set -u
  TMPDIR="$TMP" _guard_config_write "$RC25"
  printf 'NEW\n' > "$RC25"
  exit 1 ) > "$TMP/out25u" 2>&1
if grep -q 'unbound variable' "$TMP/out25u"; then
    no "25 the rollback path is set -u clean" "$(cat "$TMP/out25u")"
else
    ok "25 the rollback path is set -u clean"
fi

# 7. Wiring. The functions above do nothing until something arms them around
# the writes, and which writes are inside the window is exactly the part a
# later edit can move.
for f in "$INSTALL" "$EW"; do
    name="$(basename "$f")"
    arm="$(grep -n '^_guard_config_write "\$ZSHRC_FILE"$' "$f" | head -1 | cut -d: -f1)"
    rel="$(grep -n '^_release_config_write_guard$' "$f" | head -1 | cut -d: -f1)"
    inside="$(sed -n "$(( ${arm:-1} + 1 )),${rel:-1}p" "$f" 2>/dev/null | grep -c '_upsert_options_block "\$ZSHRC_FILE"')"
    outside="$(sed -n "${rel:-1},\$p" "$f" | grep -c '_upsert_options_block "\$ZSHRC_FILE"')"
    if [ -n "$arm" ] && [ -n "$rel" ] && [ "$arm" -lt "$rel" ] \
        && [ "$inside" -gt 0 ] && [ "$outside" -eq 0 ]; then
        ok "$name: the guard wraps the .zshrc writes and nothing after them"
    else
        no "$name: the guard wraps the .zshrc writes and nothing after them" \
           "arm=$arm rel=$rel inside=$inside outside=$outside"
    fi
done

# 8. It is shared code: the artifact nobody edits by hand has to carry the same
# body and the same message keys.
if diff <(extract_fn _undo_config_write) <(extract_fn _undo_config_write "$EW") >/dev/null 2>&1; then
    ok "25 both installers ship the same _undo_config_write"
else
    no "25 both installers ship the same _undo_config_write"
fi
if grep -q '^        i.config_undone)$' "$INSTALL" \
    && grep -q '^            i.config_undone)$' "$EW"; then
    ok "25 both installers can say what they undid"
else
    no "25 both installers can say what they undid"
fi

# ---------------------------------------------------------------------------
echo "== 26. apply_template never blanks the file it writes =="
# `cp -f src dest` and `cat > dest <<EOF` truncate the destination first and
# then discover whether they have anything to write: a source that vanished
# between resolve and apply, a download that came back empty, or a FALLBACK
# name no arm matches all leave a zero-byte .zshrc or starship.toml behind --
# and the rest of the install goes on trusting it.
extract_fn apply_template > "$TMP/lib26.sh"
# shellcheck disable=SC1090
source "$TMP/lib26.sh"

TPL_SRC="$TMP/src26"; TPL_DEST="$TMP/dest26"
printf 'GOOD TEMPLATE\n' > "$TPL_SRC"

( apply_template "LOCAL:$TPL_SRC" "$TPL_DEST" ) > "$TMP/out26a" 2>&1; rc26=$?
assert_eq "26 a local template lands in place" "$(cat "$TPL_DEST")" "GOOD TEMPLATE"
assert_eq "26 and the call succeeds" "$rc26" "0"
[ ! -e "${TPL_DEST}.zsc-new" ] && ok "26 the sibling it wrote through is gone" \
                               || no "26 the sibling it wrote through is gone"

# Now the case the old code got wrong: the destination already has content, and
# what is being applied is nothing.
printf 'USER CONFIG\n' > "$TPL_DEST"
: > "$TPL_SRC"
( apply_template "LOCAL:$TPL_SRC" "$TPL_DEST" ) > "$TMP/out26b" 2>&1; rc26=$?
[ "$rc26" -ne 0 ] && ok "26 an empty template fails the install (exit $rc26)" \
                   || no "26 an empty template fails the install"
assert_eq "26 and the existing config is untouched" "$(cat "$TPL_DEST")" "USER CONFIG"
rm -f -- "$TPL_DEST"
( apply_template "BOGUS:whatever" "$TPL_DEST" ) > "$TMP/out26c" 2>&1; rc26=$?
[ "$rc26" -ne 0 ] && ok "26 an unresolved template is not silently an empty one" \
                   || no "26 an unresolved template is not silently an empty one"
[ ! -e "$TPL_DEST" ] && ok "26 and no file is created for it" || no "26 and no file is created for it"

# Every arm of the case statement writes through the sibling, so the one thing
# the function does to $dest is rename a finished file onto it. A call site that
# reintroduced a direct write would slip past the cases above, which all fail
# before reaching that rename.
bad26="$(awk '/^apply_template\(\) \{/,/^\}/' "$INSTALL" | grep -v '^[[:space:]]*#' \
            | grep -F '"$dest"' | grep -vF 'mv -f -- "$tmp" "$dest"' \
            | grep -vF 'msg e.template_empty')"
if [ -z "$bad26" ]; then
    ok "26 apply_template touches \$dest only by renaming onto it"
else
    no "26 apply_template touches \$dest only by renaming onto it" "$bad26"
fi

# ---------------------------------------------------------------------------
echo "== 27. the mirror prefix is a URL, and it is data =="
# GH_MIRROR reaches the installer from SMART_INSTALL_GH_MIRROR or from the menu,
# and from there into every download this run performs -- including the fetch of
# third-party installers that are then executed. Two properties, one per channel
# it can go wrong: the value has to name a mirror (not a typo, not plaintext
# http), and carrying it into the download shim must not be able to say anything
# back to the shell. The second one used to be `PREFIX='$prefix'` inside an
# unquoted heredoc, so a quote in the value closed the string and the rest of it
# became code in a file every download sources.
{
    for fn in _mirror_prefix_ok _mk_dl_shim info warn error msg _msg; do
        extract_fn "$fn"
    done
} > "$TMP/lib27.sh"
# shellcheck disable=SC1090
source "$TMP/lib27.sh"
LANG_CODE=en

for good in "" "https://ghproxy.net/" "https://ghproxy.net" "https://host.example:8443/a/b" \
            "my.mirror.example" "mirror.ghproxy.com"; do
    _mirror_prefix_ok "$good" && ok "27 accepts [$good]" || no "27 accepts [$good]"
done
for bad in "http://ghproxy.net/" "https://ghproxy.net/'; touch /tmp/nope; '" \
           "https://evil.example/ && curl -s x | sh" 'https://$(id)/' \
           "https://host/a b" "file:///etc/passwd" "https:///no-host" \
           "my.mirror.example/../x" "https://ghproxy.net/
"; do
    if _mirror_prefix_ok "$bad"; then
        no "27 rejects [$(printf '%s' "$bad" | head -c 40)]"
    else
        ok "27 rejects [$(printf '%s' "$bad" | head -c 40)]"
    fi
done

# The shim itself, built from a value that is both a plausible-looking prefix
# and an attempt to run something.
SHIM27="$TMP/shim27"; mkdir -p "$SHIM27" "$TMP/bin27"
printf '#!/usr/bin/env bash\nprintf "realcurl %%s\\n" "$@" >> "%s/handoff"\n' "$TMP" > "$TMP/bin27/realcurl"
chmod +x "$TMP/bin27/realcurl"
REAL_CURL="$TMP/bin27/realcurl"; REAL_WGET=""
EVIL27="https://x.example/'; touch $TMP/pwn27; '"
rm -f -- "$TMP/pwn27" "$TMP/handoff"
_mk_dl_shim "$SHIM27" "$EVIL27" "prefix"
if grep -qF "touch $TMP/pwn27" "$SHIM27/_zsc_rw.sh" "$SHIM27/curl"; then
    no "27 the prefix stays out of the generated scripts"
else
    ok "27 the prefix stays out of the generated scripts"
fi
# Data, in the file the generated script reads at run time.
assert_has "27 the value is written as data instead" "$SHIM27/_zsc_conf" "x.example"

# Broken as it is, the value must still not swallow the download: the shim hands
# off to the real curl, and a non-github URL passes through unchanged. Running
# the shim is also the moment an injected value would land, because `curl`
# sources the rewrite script before it does anything.
"$SHIM27/curl" -o /dev/null "https://example.invalid/path" >> "$TMP/out27" 2>&1
assert_has "27 an unusable prefix still handoffs to the real curl" "$TMP/handoff" "https://example.invalid/path"
[ ! -e "$TMP/pwn27" ] && ok "27 running the shim executes nothing from the value" \
                      || no "27 running the shim executes nothing from the value"
# The witness for that absence: the marker really is creatable here, so this is
# a refusal and not a `touch` that happens to fail.
( touch "$TMP/pwn27-witness" ) >/dev/null 2>&1
[ -e "$TMP/pwn27-witness" ] && ok "27 (and the marker was creatable)" \
                             || no "27 (and the marker was creatable)"
rm -f -- "$TMP/pwn27" "$TMP/pwn27-witness"

# The behaviour the shim exists for, with a real prefix.
: > "$TMP/handoff"
_mk_dl_shim "$SHIM27" "https://ghproxy.net/" "prefix"
"$SHIM27/curl" -o /dev/null "https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh" >> "$TMP/out27" 2>&1
assert_has "27 a github URL goes through the mirror" "$TMP/handoff" "https://ghproxy.net/https://raw.githubusercontent.com/"
if grep -qF -- 'https://ghproxy.net/https://ghproxy.net/' "$TMP/handoff"; then
    no "27 rewritten once"
else
    ok "27 rewritten once"
fi
: > "$TMP/handoff"
"$SHIM27/curl" -o /dev/null "https://example.invalid/x" >> "$TMP/out27" 2>&1
assert_has "27 a non-github URL is left alone" "$TMP/handoff" "https://example.invalid/x"
# The clone type must not touch release downloads, which is what made starship
# exit 22 when it did.
: > "$TMP/handoff"
_mk_dl_shim "$SHIM27" "https://gitclone.com/" "clone"
"$SHIM27/curl" -o /dev/null "https://github.com/starship/starship/releases/download/v1.0.0/starship.tar.gz" >> "$TMP/out27" 2>&1
assert_has "27 a releases URL is never routed through a clone mirror" "$TMP/handoff" "https://github.com/starship/starship/releases"
: > "$TMP/handoff"
"$SHIM27/curl" -o /dev/null "https://github.com/imonior/zsh-smart-complete.git" >> "$TMP/out27" 2>&1
assert_has "27 but a repository URL is" "$TMP/handoff" "https://gitclone.com/github.com/imonior/zsh-smart-complete.git"
rm -rf -- "$SHIM27" "$TMP/bin27"

# Shared code again: the second installer is regenerated from the same core, and
# a divergence here would mean one of the two can be talked into a bad URL.
for fn in _mk_dl_shim _mirror_prefix_ok; do
    if diff <(extract_fn "$fn") <(extract_fn "$fn" "$EW") >/dev/null 2>&1; then
        ok "27 both installers ship the same $fn"
    else
        no "27 both installers ship the same $fn"
    fi
done
for f in "$INSTALL" "$EW"; do
    grep -q '^            mirror.rejected)$' "$f" \
        && ok "$(basename "$f"): the refusal is translated" \
        || no "$(basename "$f"): the refusal is translated"
done

# ---------------------------------------------------------------------------
echo "== 28. nothing the installer defines is left unused =="
# `_cleanup_old_baks` was dead code with a live half: its first 40 lines deleted
# the user's .bak.* files unconditionally, its second half walked three arrays
# that nothing ever filled (which `set -u` would have aborted on the spot), and
# nobody called it. Ten message keys in five languages existed for it alone.
# Nothing in the suite could notice, because no check asked whether a definition
# has a caller. These two lints are that question.
dead_fns() {
    # Names defined as a function in $1 and never mentioned again by a line that
    # is not a comment. A comment is excluded because one is exactly how a dead
    # function survives: "# (… _cleanup_conflict_residues; this earlier, partial
    # duplicate was removed …)" describes a deletion while keeping the name alive
    # in text.
    awk '
      /^[A-Za-z_][A-Za-z0-9_]*\(\)/ {
          n = $0; sub(/\(\).*/, "", n); defs[++nd] = n; next
      }
      /^[ \t]*#/ { next }
      {
          t = $0; gsub(/[^A-Za-z0-9_]+/, " ", t)
          nt = split(t, a, " ")
          for (i = 1; i <= nt; i++) used[a[i]] = 1
      }
      END { for (i = 1; i <= nd; i++) if (!(defs[i] in used)) print defs[i] }
    ' "$1"
}
for f in "$INSTALL" "$ENT"; do
    if [ -n "$(dead_fns "$f")" ]; then
        no "$(basename "$f"): every function has a caller" "$(dead_fns "$f" | tr '\n' ' ')"
    else
        ok "$(basename "$f"): every function has a caller"
    fi
done
# The detector's own witness, including the two ways it could lie: report
# nothing at all, or count a mention in a comment as a call.
{   printf 'live_fn() { :; }\n'
    printf 'commented_out() { :; }\n'
    printf '# someone should call commented_out one day\n'
    printf 'never_mentioned() { :; }\n'
    printf 'live_fn\n'
} > "$TMP/fnprobe.sh"
got="$(dead_fns "$TMP/fnprobe.sh" | sort | tr '\n' ' ')"
assert_eq "dead-function detector reports exactly the dead ones" "$got" "commented_out never_mentioned "

# Message keys are shared wholesale between the two installers -- each catalog is
# the full set so the UI cannot drift by file -- so a key is dead only when
# neither installer asks for it.
msg_keys() {
    # A key is a line of its own followed -- past any comment, which several
    # entries carry -- by the `case "$lang" in` that gives its five
    # translations. That second half is what keeps the arms of apply_template's
    # `case "$n" in` (zshrc.example, starship.toml.example) out of the set: they
    # look like keys and are not.
    awk '
      /^[ \t]+[a-z0-9_]+\.[a-z0-9_.]+\)[ \t]*$/ {
          k = $0; sub(/\)[ \t]*$/, "", k); sub(/^[ \t]+/, "", k); pend = k; next
      }
      pend && /^[ \t]*#/ { next }
      pend && /^[ \t]+case .*lang.* in[ \t]*$/ { print pend; pend = ""; next }
      { pend = "" }
    ' "$1"
}
key_called_in() {
    # `msg <key>` as a whole word: `s.backed_up` is a prefix of the live
    # `s.backed_up_removed_path`, so a plain substring search would call a dead
    # key used and the lint below would pass on the very thing it is for.
    local esc; esc="$(printf '%s' "$2" | sed 's/\./\\./g')"
    grep -qE "(^|[^[:alnum:]_])msg ${esc}([^[:alnum:]_.]|\$)" "$1" 2>/dev/null
}
key_called() { key_called_in "$INSTALL" "$1" || key_called_in "$ENT" "$1"; }
dead_keys=""
for k in $(msg_keys "$INSTALL") $(msg_keys "$ENT"); do
    key_called "$k" || dead_keys="$dead_keys $k"
done
assert_eq "every message key in either catalog is asked for somewhere" "$dead_keys" ""
# Probes for that detector: one true positive, the prefix false positive it has
# to avoid, and the whole-word positive that proves it is not simply blind.
printf 'a=$(msg probe.used_key "x")\nb=$(msg probe.used_key_longer "y")\n' > "$TMP/keyprobe.sh"
key_called_in "$TMP/keyprobe.sh" "probe.used_key" \
    && ok "key detector: finds a key that is called" || no "key detector: finds a key that is called"
key_called_in "$TMP/keyprobe.sh" "probe.used_key_longer" \
    && ok "key detector: finds the longer key too" || no "key detector: finds the longer key too"
printf 'a=$(msg probe.dead_key_longer "y")\n' > "$TMP/keyprobe2.sh"
if key_called_in "$TMP/keyprobe2.sh" "probe.dead_key"; then
    no "key detector: a longer key does not vouch for its own prefix"
else
    ok "key detector: a longer key does not vouch for its own prefix"
fi
if [ -n "$(msg_keys "$INSTALL")" ] && [ "$(msg_keys "$INSTALL" | wc -l | tr -d ' ')" -gt 200 ]; then
    ok "key detector: the catalog really was walked ($(( $(msg_keys "$INSTALL" | wc -l | tr -d ' ') )) keys)"
else
    no "key detector: the catalog walk found almost nothing, so the lint above is vacuous"
fi

# ---------------------------------------------------------------------------
echo "== 29. --uninstall takes back only what the installer wrote =="
# The strip pass is the inverse of `_upsert_options_block`, and it is the one
# place in these scripts that DELETES lines from a file the user wrote. Two
# failure modes matter: taking something that was not ours (unrecoverable --
# this is the shell config), and leaving an orphaned `zinit ice` behind.
# `zinit ice` configures whatever plugin loads NEXT, so deleting only the
# `zinit light` line would silently re-style an unrelated plugin.
{
    for fn in _zsc_in_config _zsc_strip_managed _uninstall_all; do
        extract_fn "$fn"
    done
} > "$TMP/lib29.sh"
# shellcheck disable=SC1090
source "$TMP/lib29.sh"

# The marker values are read back from install.sh rather than retyped here. An
# empty marker turns `grep -qF ""` into "match every line" and the awk below
# into "delete the file", while every assertion in this section would still
# pass -- so this is both the fixture and the check that the values are plain
# top-level assignments in the shipped script.
if eval "$(grep -E '^(ZSC|OPT)_BLOCK_(BEGIN|END)=' "$INSTALL")" \
        && [[ -n "$ZSC_BLOCK_BEGIN" && -n "$ZSC_BLOCK_END" \
              && -n "$OPT_BLOCK_BEGIN" && -n "$OPT_BLOCK_END" ]] \
        && [[ "$ZSC_BLOCK_BEGIN" != "$OPT_BLOCK_BEGIN" && "$ZSC_BLOCK_END" != "$OPT_BLOCK_END" ]]; then
    ok "29 markers read back from install.sh: non-empty and distinct"
else
    no "29 markers read back from install.sh: non-empty and distinct"
fi
if [[ "$(grep -cE '^ZSC_BLOCK_BEGIN=' "$INSTALL")" == "1" ]]; then
    ok "29 each marker is defined exactly once (with two, the fixture above silently takes the last)"
else
    no "29 each marker is defined exactly once (with two, the fixture above silently takes the last)"
fi

# The installer's own output helpers, kept on stdout so each case can be
# captured and grepped per run.
info()    { printf 'I:%s\n' "$*"; }
success() { printf 'O:%s\n' "$*"; }
warn()    { printf 'W:%s\n' "$*"; }
error()   { printf 'E:%s\n' "$*"; exit 1; }
# Echo the key AND its arguments, so "the message named the right file" is an
# assertion rather than a guess.
msg()     { local k="$1"; shift || true; printf '%s' "$k"; local a; for a in "$@"; do printf ' <%s>' "$a"; done; }
prompt_yes() { [[ "${ANSWER29:-1}" == "1" ]]; }

# 1. Both managed blocks go; everything the user wrote stays.
R29="$TMP/a29.zshrc"
{
    printf 'export MY_OWN=1\n'
    printf '%s\n' "$ZSC_BLOCK_BEGIN"
    printf 'zinit light imonior/zsh-smart-complete\n'
    printf 'autoload -Uz compinit\n'
    printf '%s\n' "$ZSC_BLOCK_END"
    printf 'alias ll="ls -l"\n'
    printf '%s\n' "$OPT_BLOCK_BEGIN"
    printf 'export SMART_MENU=true\n'
    printf '%s\n' "$OPT_BLOCK_END"
    printf 'export PATH="$PATH:/opt/bin"\n'
} > "$R29"
if _zsc_strip_managed "$R29"; then
    ok "29 the strip reports that it changed the file"
else
    no "29 the strip reports that it changed the file"
fi
assert_lacks "29 the managed content is gone" "$R29" "SMART_MENU=true"
assert_lacks "29 the markers themselves are gone too" "$R29" "$ZSC_BLOCK_BEGIN"
assert_has   "29 the line above the first block survives" "$R29" "export MY_OWN=1"
assert_has   "29 the line between the two blocks survives" "$R29" 'alias ll="ls -l"'
assert_has   "29 the line after the second block survives" "$R29" "/opt/bin"
assert_eq    "29 exactly the two blocks were removed, nothing else (3 lines survive)" "$(wc -l < "$R29" | tr -d ' ')" "3"

# 1b. The blank line the installer puts in FRONT of the block it appended goes
#     with the block. A blank line between two of the user's own stanzas does
#     not, even though the strip pass had to buffer it to know which case it was.
R29="$TMP/h29.zshrc"
printf 'export A=1\n\nalias ll="ls -l"\n\n%s\nexport SMART_MENU=true\n%s\n' \
    "$OPT_BLOCK_BEGIN" "$OPT_BLOCK_END" > "$R29"
_zsc_strip_managed "$R29"
assert_eq "29 the block's own leading blank line went with it (3 lines left)" "$(wc -l < "$R29" | tr -d ' ')" "3"
assert_eq "29 and the user's own separator is still in the same place" \
    "$(tr '\n' '|' < "$R29")" 'export A=1||alias ll="ls -l"|'
# Witness: had the fixture ended with a block in the middle of the file, both
# checks above could pass while the strip left two blank lines at EOF.
assert_eq "29 nothing trails the last user line" "$(tail -c 1 "$R29" | od -An -c | tr -d ' ')" "\\n"

# 2. The `zinit ice` pairing: the first ice belongs to ANOTHER plugin and must
#    stay with it; the second is consumed by our load line and both go.
R29="$TMP/b29.zshrc"
{
    printf 'zinit ice wait lucid\n'
    printf 'zinit light other/plugin\n'
    printf 'zinit ice wait lucid\n'
    printf 'zinit light imonior/zsh-smart-complete\n'
} > "$R29"
_zsc_strip_managed "$R29"
assert_eq "29 another plugin's zinit ice is not orphaned (2 lines left, not 3)" "$(wc -l < "$R29" | tr -d ' ')" "2"
assert_has "29 the surviving ice line is the one that still has a consumer" "$R29" "zinit light other/plugin"
assert_eq "29 and it still sits directly above that plugin" "$(sed -n '1p' "$R29")" "zinit ice wait lucid"
# Witness for the reverse mistake: an implementation that dropped every ice
# line passes the three checks above by accident.
assert_eq "29 exactly one ice line is left" "$(grep -c '^zinit ice' "$R29")" "1"

# 3. A trailing run of ice lines with no consumer at EOF is the user's, not ours.
R29="$TMP/c29.zshrc"
{
    printf 'zinit light imonior/zsh-smart-complete\n'
    printf 'zinit ice wait lucid\n'
} > "$R29"
_zsc_strip_managed "$R29"
assert_has "29 an ice line at end of file is flushed back, not swallowed" "$R29" "zinit ice wait lucid"
assert_eq "29 and only our load line was removed" "$(wc -l < "$R29" | tr -d ' ')" "1"

# 4. The pre-marker forms: indented inside an `if`, and the `zinit load` spelling.
R29="$TMP/d29.zshrc"
{
    printf 'if [[ -f "$ZINIT_HOME/zinit.zsh" ]]; then\n'
    printf '    zinit ice wait lucid\n'
    printf '    zinit light zdharma-continuum/fast-syntax-highlighting\n'
    printf '    zinit light imonior/zsh-smart-complete\n'
    printf 'fi\n'
} > "$R29"
_zsc_strip_managed "$R29"
assert_lacks "29 an indented (inside-if) load line is matched too" "$R29" "zinit light imonior"
assert_has "29 the if block is left intact and still loads the other plugin" "$R29" "fast-syntax-highlighting"
assert_eq "29 the block is still closed, so the config parses" "$(tail -1 "$R29")" "fi"
R29="$TMP/e29.zshrc"
printf 'zinit ice wait\nzinit load imonior/zsh-smart-complete\n' > "$R29"
_zsc_strip_managed "$R29"
assert_eq "29 the zinit load spelling is handled as well" "$(wc -l < "$R29" | tr -d ' ')" "0"

# 5. Nothing of ours: report no change, and do not touch the file.
R29="$TMP/f29.zshrc"
printf 'export MY_OWN=1\nalias ll="ls -l"\n' > "$R29"
cp -p "$R29" "$R29.ref"
if _zsc_strip_managed "$R29"; then
    no "29 a config with nothing of ours reports NO change (a false 'yes' would fake a cleanup)"
else
    ok "29 a config with nothing of ours reports NO change (a false 'yes' would fake a cleanup)"
fi
cmp -s "$R29" "$R29.ref" && ok "29 and it is left byte for byte identical" || no "29 and it is left byte for byte identical"
if _zsc_in_config "$R29"; then no "29 _zsc_in_config calls a clean config ours"; else ok "29 _zsc_in_config calls a clean config NOT ours"; fi
if _zsc_in_config "$TMP/does-not-exist-29"; then no "29 a missing config is not ours"; else ok "29 a missing config is not ours"; fi
# A half-removed config (only an END marker left over from an older or
# interrupted run) still counts, because the strip pass is what fixes it.
printf 'x\n%s\n' "$OPT_BLOCK_END" > "$R29"
if _zsc_in_config "$R29"; then ok "29 a lone END marker still counts as ours"; else no "29 a lone END marker still counts as ours"; fi

# 6. Permissions. The strip writes a temp and renames over the file, and mktemp
#    hands out 0600 -- without the cp -p an uninstall would quietly tighten
#    ~/.zshrc on every machine it touches.
R29="$TMP/g29.zshrc"
printf '%s\nexport SMART_MENU=true\n%s\n' "$OPT_BLOCK_BEGIN" "$OPT_BLOCK_END" > "$R29"
chmod 644 "$R29"
_zsc_strip_managed "$R29"
assert_eq "29 the config keeps the mode it had" "$(ls -l "$R29" | cut -c2-10)" "rw-r--r--"
assert_eq "29 and no .zsc-strip temp file is left in the directory" \
    "$(find "$(dirname "$R29")" -name '.zsc-strip.*' | wc -l | tr -d ' ')" "0"

# 7. The uninstall driver, against a fake $HOME.
home29() {   # point every path the driver derives at $1
    local h="$1"
    rm -rf "$h"; mkdir -p "$h"
    printf 'export MY_OWN=1\nalias ll="ls -l"\n' > "$h/.zshrc"
    HOME="$h"; ZDOTDIR="$h"; XDG_DATA_HOME=""; XDG_CONFIG_HOME=""
    unset ZSHRC_FILE SMART_COMPLETE_INSTALL_DIR
}

#    Nothing installed: say so, and do not even ask.
H="$TMP/home29-clean"
( home29 "$H"
  _uninstall_all > "$TMP/out29a" 2>&1 )
assert_has "29 with nothing installed it says there is nothing to remove" "$TMP/out29a" "u.nothing"
assert_lacks "29 and it does not ask for confirmation first" "$TMP/out29a" "u.confirm"
assert_eq  "29 the user's config is untouched" "$(cat "$H/.zshrc")" "$(printf 'export MY_OWN=1\nalias ll="ls -l"')"

#    Installed, and the answer is NO.
H="$TMP/home29-declined"
( home29 "$H"
  { printf '%s\n' "$ZSC_BLOCK_BEGIN"
    printf 'zinit light imonior/zsh-smart-complete\n'
    printf '%s\n' "$ZSC_BLOCK_END"; } >> "$H/.zshrc"
  mkdir -p "$H/.local/share/zinit/plugins/imonior---zsh-smart-complete"
  ANSWER29=0
  _uninstall_all > "$TMP/out29b" 2>&1 )
assert_has "29 declining the confirmation cancels" "$TMP/out29b" "u.cancelled"
assert_has "29 a declined uninstall leaves the config block in place" "$H/.zshrc" "zinit light imonior/zsh-smart-complete"
assert_eq "29 and the plugin checkout is still there" \
    "$([[ -d "$H/.local/share/zinit/plugins/imonior---zsh-smart-complete" ]] && echo yes || echo no)" "yes"

#    Installed, and the answer is YES.
H="$TMP/home29-yes"
( home29 "$H"
  { printf '%s\n' "$OPT_BLOCK_BEGIN"
    printf 'export SMART_MENU=true\n'
    printf '%s\n' "$OPT_BLOCK_END"; } >> "$H/.zshrc"
  P="$H/.local/share/zinit/plugins/imonior---zsh-smart-complete"
  mkdir -p "$P/bin" "$H/.config/zsh-smart-complete" "$H/.local/bin"
  printf 'plugin\n' > "$P/zsh-smart-complete.plugin.zsh"
  printf '#!/bin/zsh\n' > "$P/bin/zsc-settings"; chmod +x "$P/bin/zsc-settings"
  printf 'SMART_MENU=true\n' > "$H/.config/zsh-smart-complete/settings.zsh"
  ln -s "$P/bin/zsc-settings" "$H/.local/bin/zsc-settings"
  # Files with the same names that somebody else put there must survive.
  ln -s "/somewhere/else/zsc-settings" "$H/.local/bin/zsc-settings.foreign"
  printf '[palettes]\n' > "$H/.config/starship.toml"
  ANSWER29=1
  _uninstall_all > "$TMP/out29c" 2>&1 )
assert_lacks "29 the managed block is gone from the config" "$H/.zshrc" "SMART_MENU=true"
assert_has   "29 the user's own lines are still there" "$H/.zshrc" "alias ll"
assert_eq    "29 the plugin checkout is gone" \
    "$([[ -e "$H/.local/share/zinit/plugins/imonior---zsh-smart-complete" ]] && echo yes || echo no)" "no"
assert_eq    "29 settings.zsh is gone, and its now-empty directory with it" \
    "$([[ -e "$H/.config/zsh-smart-complete" ]] && echo yes || echo no)" "no"
assert_eq    "29 the settings symlink we made is gone" \
    "$([[ -e "$H/.local/bin/zsc-settings" ]] && echo yes || echo no)" "no"
assert_eq    "29 a same-named symlink to someone else's file is left alone" \
    "$([[ -L "$H/.local/bin/zsc-settings.foreign" ]] && echo yes || echo no)" "yes"
assert_eq    "29 the prompt config is left alone (an uninstall is not a package purge)" \
    "$([[ -f "$H/.config/starship.toml" ]] && echo yes || echo no)" "yes"
assert_lacks "29 and nothing in the output claims to have deleted it" "$TMP/out29c" "starship.toml"
assert_has   "29 the run ends by telling the user to restart the shell" "$TMP/out29c" "u.done"

#    The backup: written BEFORE the edit, and it still holds what was removed.
BK="$(find "$H" -maxdepth 1 -name '.zshrc.bak.*' 2>/dev/null | head -1)"
if [[ -n "$BK" ]] && grep -q "SMART_MENU=true" "$BK"; then
    ok "29 the config was backed up before it was edited, and the backup holds the removed block"
else
    no "29 the config was backed up before it was edited, and the backup holds the removed block"
fi
assert_has "29 and it says where that backup is" "$TMP/out29c" "u.backup <"

#    A backup name that is ALREADY TAKEN is stepped around, never overwritten.
#    The name has second resolution, and "install, then undo that install" is
#    exactly the pair of runs that can land in one second — where a plain `cp`
#    replaces the copy the install made, which is the single version of a
#    hand-written config this line exists to keep. `date` is a shell function for
#    the duration of this subshell, so the colliding second is fixed here rather
#    than being a race the test happens to win.
H="$TMP/home29-collide"
( home29 "$H"
  { printf '%s\n' "$OPT_BLOCK_BEGIN"
    printf 'export SMART_MENU=true\n'
    printf '%s\n' "$OPT_BLOCK_END"; } >> "$H/.zshrc"
  mkdir -p "$H/.local/share/zinit/plugins/imonior---zsh-smart-complete"
  date() { printf '1790000000\n'; }
  printf 'THE INSTALL COPY\n' > "$H/.zshrc.bak.1790000000"
  ANSWER29=1
  _uninstall_all > "$TMP/out29e" 2>&1 )
if grep -q "THE INSTALL COPY" "$H/.zshrc.bak.1790000000" 2>/dev/null; then
    ok "29 an already-existing backup keeps its own contents"
else
    no "29 an already-existing backup keeps its own contents" \
       "got: $(cat "$H/.zshrc.bak.1790000000" 2>/dev/null)"
fi
assert_has "29 and the uninstall wrote its copy under a stepped name" "$TMP/out29e" ".zshrc.bak.1790000000-1>"
assert_eq "29 so the directory holds two backups, not one overwritten file" \
    "$(find "$H" -maxdepth 1 -name '.zshrc.bak.*' 2>/dev/null | wc -l | tr -d ' ')" "2"

#    A config that cannot be backed up is not edited at all. Root ignores file
#    permissions, so this one can only be checked as an ordinary user.
if [[ "$(id -u)" != "0" ]]; then
    H="$TMP/home29-nobak"
    ( home29 "$H"
      printf '%s\nexport SMART_MENU=true\n%s\n' "$OPT_BLOCK_BEGIN" "$OPT_BLOCK_END" >> "$H/.zshrc"
      cp -p "$H/.zshrc" "$H/.zshrc.ref"
      chmod 555 "$H"
      ANSWER29=1
      _uninstall_all > "$TMP/out29d" 2>&1 )
    chmod 755 "$H"
    cmp -s "$H/.zshrc" "$H/.zshrc.ref" \
        && ok "29 with nowhere to put a backup it refuses to edit the config" \
        || no "29 with nowhere to put a backup it refuses to edit the config"
    assert_has "29 and it says why" "$TMP/out29d" "u.backup_failed"
    assert_lacks "29 an aborted uninstall does not claim the cleanup it did not do" "$TMP/out29d" "u.done"
    assert_lacks "29 nor does it remove the plugin directory on the way out" "$TMP/out29d" "u.removed"
fi

# 8. Wiring: the request is handled once the language is known and before any
#    phase runs -- an uninstall that starts by installing a missing zsh is not
#    an uninstall. The "first install action" anchor differs per installer.
for f in "$INSTALL" "$EW"; do
    name="$(basename "$f")"
    if [[ "$f" == "$INSTALL" ]]; then anchor='^OS_TYPE=""'; else anchor='^if command -v opkg >/dev/null 2>&1; then'; fi
    lang29="$(grep -n '^select_language$' "$f" | head -1 | cut -d: -f1)"
    dsp="$(grep -n 'SMART_UNINSTALL:-0' "$f" | head -1 | cut -d: -f1)"
    first="$(grep -n "$anchor" "$f" | head -1 | cut -d: -f1)"
    if [[ -n "$lang29" && -n "$dsp" && -n "$first" ]] && (( lang29 < dsp && dsp < first )); then
        ok "$name handles the uninstall after the language is chosen and before anything installs (lang=$lang29 dispatch=$dsp first=$first)"
    else
        no "$name handles the uninstall after the language is chosen and before anything installs (lang=$lang29 dispatch=$dsp first=$first)"
    fi
done
assert_has "install.sh forwards its arguments to the entware installer it hands off to" \
    "$INSTALL" 'exec bash "$ENTWARE_INSTALLER" "$@"'

# 9. Shared code: both artifacts must carry the same bodies, or one of them is
#    uninstalling with an older idea of what we wrote.
for fn in _zsc_in_config _zsc_strip_managed _uninstall_all; do
    if diff <(extract_fn "$fn") <(extract_fn "$fn" "$EW") > /dev/null 2>&1; then
        ok "29 both installers ship the same $fn"
    else
        no "29 both installers ship the same $fn"
    fi
done

# 10. Every key the shared uninstall code prints is in both catalogs, in all 5
#     languages.
key_langs(){
    awk -v k="$2" '
        !inblk && $0 ~ "^[[:space:]]+" k "\\)" { inblk = 1; next }
        inblk && /esac/ { exit }
        inblk { t = t $0 "\n" }
        END {
            n = 0
            if (t ~ /zh-CN\)/) n++
            if (t ~ /zh-TW\)/) n++
            if (t ~ /[^-]ja\)/) n++
            if (t ~ /ko\)/) n++
            if (t ~ /\*\)/) n++
            print n
        }' "$1"
}
# Probe first: an entry with a single language has to count as 1, or the loop
# below would pass on a detector that never finds anything.
printf '        probe.key)\n            case "$lang" in\n                zh-CN) s="x" ;;\n            esac ;;\n' > "$TMP/probe29.txt"
assert_eq "29 the language counter is real (a one-language entry counts 1)" \
    "$(key_langs "$TMP/probe29.txt" probe.key)" "1"
for k in u.confirm u.cancelled u.nothing u.backup u.backup_failed u.stripped u.removed u.done; do
    if [[ "$(key_langs "$INSTALL" "$k")" == "5" && "$(key_langs "$EW" "$k")" == "5" ]]; then
        ok "29 $k is translated in all 5 languages in both installers"
    else
        no "29 $k is translated in all 5 languages in both installers (install=$(key_langs "$INSTALL" "$k") entware=$(key_langs "$EW" "$k"))"
    fi
done


echo "-----"
echo "INSTALLER-OPTIONS TOTAL PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
