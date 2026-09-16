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
# Function bodies in install.sh end with `}` in column 0.
# ---------------------------------------------------------------------------
extract_fn(){ sed -n "/^$1() {/,/^}/p" "$INSTALL"; }

{
    # The answered-options defaults (everything from ZSC_OPT_MENU=1 up to and
    # including the one-line _zsc_bool helper).
    sed -n '/^ZSC_OPT_MENU=1/,/^_zsc_bool() {/p' "$INSTALL"
    # The marker constants.
    grep -E '^(ZSC|OPT)_BLOCK_(BEGIN|END)=' "$INSTALL"
    extract_fn build_smart_options
    extract_fn _upsert_options_block
} > "$TMP/lib.sh"

echo "== 0. extraction =="
for fn in build_smart_options _upsert_options_block; do
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
assert_has "default: single column on"      "$D" 'export SMART_MENU_SINGLE_COLUMN=true'
assert_has "default: recent paths on"       "$D" 'export SMART_RECENT_PATHS=true'
assert_has "default: history keys OFF"      "$D" 'export SMART_MENU_HISTORY_KEYS=false'
assert_has "default: strategy is history"   "$D" 'export SMART_SUGGEST_STRATEGY="history"'
assert_lacks "default: no fzf-tab"          "$D" 'fzf-tab'

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
assert_eq "SMART_NATIVE_MENU_SELECT default agrees" "$(_zsc_bool "$ZSC_OPT_NATIVE_MENU")"   "$(_cfg_default SMART_NATIVE_MENU_SELECT)"
assert_eq "SMART_SUGGEST_STRATEGY default agrees"   "$ZSC_OPT_STRATEGY"                      "$(_cfg_default SMART_SUGGEST_STRATEGY)"

echo "== 3. answers are honoured, including the non-default ones =="
ZSC_OPT_MENU=0; ZSC_OPT_SINGLE_COLUMN=0; ZSC_OPT_RECENT_PATHS=0
ZSC_OPT_HISTORY_KEYS=1; ZSC_OPT_NATIVE_MENU=1; ZSC_OPT_FZF_TAB=0
ZSC_OPT_STRATEGY="history,completion"
D="$TMP/answers.zshrc"; build_smart_options > "$D"
assert_has "popup off"                "$D" 'export SMART_MENU=false'
assert_has "multi-column grid chosen" "$D" 'export SMART_MENU_SINGLE_COLUMN=false'
assert_has "recent paths off"         "$D" 'export SMART_RECENT_PATHS=false'
assert_has "history keys on"          "$D" 'export SMART_MENU_HISTORY_KEYS=true'
assert_has "native Tab menu on"       "$D" 'export SMART_NATIVE_MENU_SELECT=true'
assert_has "strategy list written"    "$D" 'export SMART_SUGGEST_STRATEGY="history,completion"'

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
# install-entware.sh is a separate, standalone script (fetched on its own), so
# it cannot share code with install.sh — which means it can silently drift.
# These assertions are the cheap tripwire: the questions, the builder and the
# managed block must all be present there too.
ENT="$REPO/install-entware.sh"
if [ -f "$ENT" ]; then
    for fn in build_smart_options _upsert_options_block ask_smart_options _zsc_bool; do
        if grep -q "^$fn() {" "$ENT"; then ok "entware defines $fn"; else no "entware is missing $fn"; fi
    done
    assert_has "entware has the options markers" "$ENT" 'OPT_BLOCK_BEGIN="# >>> zsh-smart-complete options (managed) >>>"'
    assert_has "entware writes the options block" "$ENT" '_upsert_options_block "$ZSHRC_FILE" "$(build_smart_options)"'
    assert_has "entware asks about fzf-tab" "$ENT" "opt.fzf_tab"
    # The questionnaire must not use install.sh's /dev/tty reader: Entware has
    # no _tty_read helper, so a copied call would break the prompts.
    if grep -q '_tty_read -r REPLY' "$ENT"; then
        no "entware questionnaire calls _tty_read (undefined there)"
    else
        ok "entware questionnaire uses a plain read"
    fi
    # And its own plugin-clone helper, since _ensure_zinit_plugin is install.sh-only.
    if grep -q '^_entware_ensure_zinit_plugin() {' "$ENT"; then
        ok "entware has its own zinit plugin helper"
    else
        no "entware questionnaire would call an undefined _ensure_zinit_plugin"
    fi
else
    no "install-entware.sh is missing"
fi

echo "-----"
echo "INSTALLER-OPTIONS TOTAL PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
