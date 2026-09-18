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
assert_has "default: single column OFF"     "$D" 'export SMART_MENU_SINGLE_COLUMN=false'
assert_has "default: recent paths on"       "$D" 'export SMART_RECENT_PATHS=true'
assert_has "default: history keys OFF"      "$D" 'export SMART_MENU_HISTORY_KEYS=false'
assert_has "default: strategy is history"   "$D" 'export SMART_SUGGEST_STRATEGY="history"'
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
    extract_fn select_mirror
} > "$TMP/region.sh"
# shellcheck disable=SC1090
source "$TMP/region.sh"
for fn in detect_public_ip_region select_mirror mirror_speed_test; do
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

echo "-----"
echo "INSTALLER-OPTIONS TOTAL PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
