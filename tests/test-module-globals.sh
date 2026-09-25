#!/usr/bin/env bash
# tests/test-module-globals.sh
#
# Checks the checker: tools/check-module-globals.sh, which keeps the boundary
# lib/state.zsh draws between "runtime state, which lives in the container" and
# "global that needs a reason, which lives in the register at the bottom of that
# file".
#
# WHY THIS SUITE EXISTS
#   lib/state.zsh asserted that no standalone `_smart_thing=foo` existed anywhere
#   else in the codebase. It was wrong, by dozens of globals, and the wrongness
#   was load-bearing in the bad direction: a reader who believed the comment had
#   no way to find the rest of the state, and a writer who added one hit no
#   friction. Measured first (a container subscript costs well under a
#   microsecond per read, against ~0.4 ms for the $() an accessor would require),
#   migrating everything is not what makes the comment true again — saying what
#   the boundary actually is, and refusing to ship a new global without a stated
#   reason, is.
#
#   That makes this suite the important one here: a lint nobody can prove works
#   is a lint that reports green. So every check runs twice — once on the real
#   tree, where it must pass, and once against a fixture built to trip it.
#
# SECTION MAP
#   1  the real tree passes, and the walk found a real amount of code
#   2  --list enumerates names, sites and their declaration kind
#   3  UNDECLARED fires when a register line is removed
#   4  an empty register reports every name (the vacuity witness)
#   5  STALE fires for a register entry that matches nothing
#   6  NO REASON fires when the two-space separator is missing
#   7  which spellings count as a global declaration, and which do not
#   8  IMPLICIT fires for a name that is only ever assigned
#   9  DEAD KEY fires for a documented state key nobody uses
#  10  register hygiene on the real file
#  11  it is wired up and path-independent
#  12  the false claim is gone from lib/state.zsh

set -u

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPO/tools/check-module-globals.sh"
STATE="$REPO/lib/state.zsh"
RUNALL="$REPO/tests/run-all.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1" >&2; [ $# -gt 1 ] && printf '        %s\n' "$2" >&2; return 0; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then ok "$name"; else no "$name" "got=[$got] want=[$want]"; fi
}
assert_ge() {
    local name="$1" got="$2" want="$3"
    if [ "x$got" != "x" ] && [ "$got" -ge "$want" ] 2>/dev/null; then ok "$name"; else no "$name" "[$got] < $want"; fi
}
assert_has() {
    local name="$1" hay="$2" needle="$3"
    if printf '%s\n' "$hay" | grep -qF -- "$needle"; then ok "$name"; else no "$name" "missing [$needle]"; fi
}
assert_no() {
    local name="$1" hay="$2" needle="$3"
    if printf '%s\n' "$hay" | grep -qF -- "$needle"; then no "$name" "found [$needle]"; else ok "$name"; fi
}
assert_count() {
    # How many report lines carry a given label. The third argument is the
    # expectation, so a probe never passes by reporting nothing.
    local name="$1" label="$2" hay="$3" want="$4" got
    got="$(printf '%s\n' "$hay" | grep -c "^$label" || true)"
    assert_eq "$name" "$got" "$want"
}

for f in "$CHECK" "$STATE" "$RUNALL"; do
    [ -f "$f" ] || { printf 'MODULE-GLOBALS TOTAL PASS=0 FAIL=1 SKIP (%s missing)\n' "$f"; exit 1; }
done

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/zsc-globals.XXXXXX")" || TMPD=""
if [ -z "$TMPD" ]; then
    printf 'MODULE-GLOBALS TOTAL PASS=0 FAIL=1 SKIP (could not create a temp dir)\n'
    exit 1
fi
trap 'rm -rf -- "$TMPD"' EXIT

# Run the checker, capturing its report AND its exit status from one invocation:
# the verdict is the assertion, so it cannot be re-derived from a second run that
# sees a different tree. Sets $out and $RC.
RC=0
run_check() {
    local out="$1"; shift
    bash "$CHECK" "$@" > "$TMPD/rc.out" 2>&1
    RC=$?
    eval "$out=\$(cat -- \"\$TMPD/rc.out\")"
}

printf '== 1. the real tree passes ==\n'
run_check real
assert_eq "the check exits 0 on lib/" "0" "$RC"
assert_has "and says so" "$real" "all covered"
# A green run only means something if the scan looked at the code. These floors
# describe the shape of the tree rather than an exact count: they fail if the
# walker stops matching anything, which is how a lint goes silently green.
summary="$(printf '%s\n' "$real" | grep 'module-globals:' | tail -n 1)"
# Each field is anchored to the text that PRECEDES it, not just to the number:
# `.*\([0-9]\{1,\}\) register pattern` looks reasonable and silently returns the
# "8" of "38", because a greedy prefix leaves the shortest possible digit run.
n_names="$(printf '%s' "$summary" | sed -n 's/^module-globals: \([0-9]\{1,\}\) name.*/\1/p')"
n_sites="$(printf '%s' "$summary" | sed -n 's/.* in \([0-9]\{1,\}\) declaration.*/\1/p')"
n_pats="$(printf '%s' "$summary" | sed -n 's/.*, \([0-9]\{1,\}\) register pattern.*/\1/p')"
n_docs="$(printf '%s' "$summary" | sed -n 's/.*, \([0-9]\{1,\}\) documented key.*/\1/p')"
assert_eq "all four counts parsed" "4" \
    "$(printf '%s\n' "$n_names" "$n_sites" "$n_pats" "$n_docs" | grep -cE '^[0-9]+$')"
assert_ge "globals enumerated"             "${n_names:-}" 60
assert_ge "declaration sites enumerated"   "${n_sites:-}" 150
assert_ge "register patterns parsed"       "${n_pats:-}"  25
assert_ge "documented state keys parsed"   "${n_docs:-}"  15
# More sites than names proves the walker follows repeat writes, not just the
# first line per file: a name declared once and written nine times is the norm
# here, and one-site-per-name would mean the scan is reading a fixed line set.
assert_ge "sites outnumber names" "$n_sites" "$(( n_names + 100 ))"
# --register must be honoured, or every fixture section below is theatre.
: > "$TMPD/reg-none"
run_check emptyreg --register "$TMPD/reg-none"
assert_eq "pointing --register at an empty file changes the verdict" "1" "$RC"

printf '\n== 2. --list enumerates ==\n'
run_check list --list
assert_eq "--list reports, without verdicts" "0" "$RC"
list_names="$(printf '%s\n' "$list" | grep -E '^_SMART' | awk '{print $1}' | sort)"
assert_eq "one row per name" "$(printf '%s\n' "$list_names" | grep -c .)" "$n_names"
assert_has "a typeset-declared global is listed" "$list" "_SMART_MENU_LISTER_RET"
assert_has "a glob-covered member is listed"     "$list" "_SMART_EVT_ORIG_SELF_EMACS"
assert_has "the container itself is listed"      "$list" "_SMART_STATE_A"
assert_has "rows carry file:line"                "$list" "lib/engine/menu.zsh:"
assert_eq "a name declared once and written often appears once" \
    "$(printf '%s\n' "$list_names" | grep -c '^_SMART_CMDS$')" "1"
probe_row="$(printf '%s\n' "$list" | grep '^_SMART_PROBE_SUFFIX_RET')"
assert_has "the probe slot that used to be assignment-only now resolves to a file" \
    "$probe_row" "lib/engine/menu.zsh:"
assert_no "and it is no longer flagged as an undeclared write" \
    "$probe_row" "(assigned, not declared)"

printf '\n== 3. UNDECLARED: remove the one line that covers twenty names ==\n'
# The strongest proof available that the register is load-bearing rather than
# decorative: delete ONE line and twenty globals stop being accounted for.
grep -v '^# GLOBAL: _SMART_EVT_ORIG_\*  ' "$STATE" > "$TMPD/reg-noglob"
assert_eq "the fixture really dropped one line" \
    "$(( $(grep -c '' "$STATE") - $(grep -c '' "$TMPD/reg-noglob") ))" "1"
run_check noglob --register "$TMPD/reg-noglob"
assert_eq "removing one register line fails the check" "1" "$RC"
assert_count "exactly the twenty it covered are UNDECLARED" UNDECLARED "$noglob" "20"
assert_has "one of them named specifically" "$noglob" "_SMART_EVT_ORIG_SELF_EMACS"
assert_no "and nothing else moved" "$noglob" "_SMART_MENU_ROWS"

printf '\n== 4. an empty register reports every name (vacuity witness) ==\n'
run_check none --register "$TMPD/reg-none"
assert_eq "empty register fails" "1" "$RC"
assert_count "every name is UNDECLARED" UNDECLARED "$none" "$n_names"
assert_count "nothing is STALE (there was nothing to be stale)" STALE "$none" "0"

printf '\n== 5. STALE: a register entry that matches nothing ==\n'
cat "$STATE" > "$TMPD/reg-stale"
printf '# GLOBAL: _SMART_RETIRED_LONG_AGO  this name is gone\n' >> "$TMPD/reg-stale"
run_check stale --register "$TMPD/reg-stale"
assert_eq "an entry nobody matches fails" "1" "$RC"
assert_count "exactly one entry is STALE" STALE "$stale" "1"
assert_has "named by pattern" "$stale" "_SMART_RETIRED_LONG_AGO"
# A typo in a register line is the same failure in a more confusing costume: it
# looks like coverage while leaving the real name unaccounted for.
sed 's/^# GLOBAL: _SMART_MENU_ROWS  /# GLOBAL: _SMART_MENU_ROW  /' "$STATE" > "$TMPD/reg-typo"
assert_eq "the typo fixture has the same line count" \
    "$(( $(grep -c '' "$STATE") - $(grep -c '' "$TMPD/reg-typo") ))" "0"
run_check typo --register "$TMPD/reg-typo"
assert_eq "a mistyped pattern fails on both ends" "1" "$RC"
assert_count "STALE for the pattern that matches nothing" STALE "$typo" "1"
assert_count "UNDECLARED for the name that lost its cover" UNDECLARED "$typo" "1"
assert_has "naming the row counter" "$typo" "_SMART_MENU_ROWS"

printf '\n== 6. NO REASON: the two-space separator is the field boundary ==\n'
sed 's/^# GLOBAL: _SMART_MENU_ROWS  /# GLOBAL: _SMART_MENU_ROWS /' "$STATE" > "$TMPD/reg-noreason"
run_check noreason --register "$TMPD/reg-noreason"
assert_eq "one space instead of two reads as no reason" "1" "$RC"
assert_count "reported as NO REASON" "NO REASON" "$noreason" "1"
assert_has "naming the entry at fault" "$noreason" "_SMART_MENU_ROWS"

printf '\n== 7. which spellings count as a global declaration ==\n'
cat > "$TMPD/src-shapes.zsh" <<'ZSH'
typeset -g _SMART_TOPLEVEL=1
typeset -gA _SMART_TOPASSOC=()
typeset -gaU _SMART_TOPLIST=()
_zsm_fn() {
    typeset -g _SMART_INFN=1
    _SMART_INDENT_BARE=2
    _SMART_SUBSCRIPT[k]=3
    local _SMART_A_LOCAL=4
    : ${_SMART_A_TUNABLE:=5}
    print -r -- "${_SMART_READONLY_LOOK:-} ${_SMART_TOPLEVEL}"
}
# typeset -g _SMART_IN_A_COMMENT=6
#   _SMART_DOC_EXAMPLE=7
ZSH
run_check shapes --list --register "$TMPD/reg-none" --source "$TMPD/src-shapes.zsh"
# LC_ALL=C because the expectation is a byte order: a collation that ignores the
# case and punctuation would reorder this list on another machine, and the
# assertion is about the SET the checker found, not about locale.
found="$(printf '%s\n' "$shapes" | grep -E '^_SMART' | awk '{print $1}' | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "the enumerated set is exactly the six globals" \
    "$found" "_SMART_INDENT_BARE _SMART_INFN _SMART_SUBSCRIPT _SMART_TOPASSOC _SMART_TOPLEVEL _SMART_TOPLIST "
for n in _SMART_A_LOCAL _SMART_A_TUNABLE _SMART_IN_A_COMMENT _SMART_DOC_EXAMPLE _SMART_READONLY_LOOK; do
    assert_no "and NOT a global: $n" "$found" "$n"
done
# Only three of the six registered: the other three must be named individually.
printf '%s\n' '# GLOBAL: _SMART_TOPLEVEL  declared' \
              '# GLOBAL: _SMART_TOPASSOC  declared' \
              '# GLOBAL: _SMART_TOPLIST  declared' > "$TMPD/reg-shapes"
run_check partly --register "$TMPD/reg-shapes" --source "$TMPD/src-shapes.zsh"
assert_eq "a source with unregistered globals fails" "1" "$RC"
assert_count "naming each of the three" UNDECLARED "$partly" "3"
assert_has "including the one declared inside a function" "$partly" "_SMART_INFN"

printf '\n== 8. IMPLICIT: assigned but never declared ==\n'
# Under `no_warn_create_global` the first write to an undeclared name silently
# makes it a global, so a name can be reachable, registered, and invisible to
# anything that reads declarations. This codebase had two such names.
cat > "$TMPD/src-implicit.zsh" <<'ZSH'
_zsm() {
    _SMART_ONLY_ASSIGNED=""
}
ZSH
printf '# GLOBAL: _SMART_ONLY_ASSIGNED  a return slot\n' > "$TMPD/reg-implicit"
run_check implicit --register "$TMPD/reg-implicit" --source "$TMPD/src-implicit.zsh"
assert_eq "registered but undeclared fails" "1" "$RC"
assert_count "reported as IMPLICIT" IMPLICIT "$implicit" "1"
assert_has "with the file:line of the write" "$implicit" "src-implicit.zsh:2"
# Both directions of the marker, from the same two files, so the assertion at the
# end of section 2 (a real name that IS declared) cannot pass just because the
# marker is never printed at all.
run_check implicitlist --list --register "$TMPD/reg-implicit" --source "$TMPD/src-implicit.zsh"
assert_has "the listing marks an assignment-only global as such" \
    "$implicitlist" "(assigned, not declared)"
{ printf 'typeset -g _SMART_ONLY_ASSIGNED=""\n'; cat "$TMPD/src-implicit.zsh"; } > "$TMPD/src-declared.zsh"
run_check declaredlist --list --register "$TMPD/reg-implicit" --source "$TMPD/src-declared.zsh"
assert_no "and stops once there is a declaration" "$declaredlist" "(assigned, not declared)"
run_check declared --register "$TMPD/reg-implicit" --source "$TMPD/src-declared.zsh"
assert_eq "declaring it is the whole fix" "0" "$RC"
assert_no "and lib/ has none left" "$real" "IMPLICIT"

printf '\n== 9. DEAD KEY: a documented state key nobody uses ==\n'
# Two of the container's documented keys had drifted from the code: a
# `history.freq` for a map named `history.frequency`, and a `history.first_char`
# nothing ever wrote. The doc is what a port reads first, so a stale entry there
# is a bug report waiting to be filed against code that was never missing.
cat > "$TMPD/reg-deadkey" <<'REG'
# Canonical keys in _SMART_STATE (documented for future porting to Rust):
#
#   enabled                "1" / "0"          -- master runtime toggle
#   history.never_written  number             -- a TODO nobody implemented
#                          age = tick - stored, 0 = just used
REG
cat > "$TMPD/src-keys.zsh" <<'ZSH'
_smart_state_set enabled 1
ZSH
run_check deadkey --register "$TMPD/reg-deadkey" --source "$TMPD/src-keys.zsh"
assert_eq "a documented key with no user fails" "1" "$RC"
assert_count "reported as DEAD KEY" "DEAD KEY" "$deadkey" "1"
assert_has "naming the dead key" "$deadkey" "history.never_written"
# The fixture's continuation row ("age = tick …") is prose indented past the key
# column. Without the indent anchor it would be parsed as a key named `age`, so
# the two assertions below are the whole point of that fixture line.
assert_no "a doc continuation line is not a key" "$deadkey" "DEAD KEY    age"
assert_no "the key that IS used passes" "$deadkey" "DEAD KEY    enabled"
assert_has "and the real doc's keys all pass" "$real" "$n_docs documented key"

printf '\n== 10. register hygiene on the real file ==\n'
reg_lines="$(grep '^# GLOBAL: ' "$STATE")"
reg_total="$(printf '%s\n' "$reg_lines" | grep -c .)"
# The pattern is the field before the two-space separator; every assertion below
# that talks about a pattern has to strip the reason first, because the reasons
# are prose and full of commas.
reg_pats() { printf '%s\n' "$reg_lines" | sed 's/^# GLOBAL: //; s/  .*//'; }
reg_why()  { printf '%s\n' "$reg_lines" | sed 's/^# GLOBAL: [^ ]*  //'; }
assert_eq "every register line has a pattern then a two-space reason" \
    "$(printf '%s\n' "$reg_lines" | grep -cE '^# GLOBAL: [^ ]+  [^ ]')" "$reg_total"
assert_eq "no line stuffs two patterns in one field" \
    "$(reg_pats | grep -c ',')" "0"
assert_eq "no pattern is registered twice" "$(reg_pats | sort | uniq -d | grep -c .)" "0"
assert_eq "the parsed pattern count equals the line count" "$n_pats" "$reg_total"
# The shape rule is what stops a register entry from covering the tree by
# accident: `_SMART` plus word characters, with `*` allowed only as a glob
# inside a name. `*`, `_SMART*` and `.*` would all be "valid" globs that make the
# register meaningless.
assert_eq "every pattern is _SMART-shaped, globs included" \
    "$(reg_pats | grep -cvE '^_SMART[A-Za-z0-9_]*\*?[A-Za-z0-9_]*$')" "0"
assert_eq "and none of them starts with a wildcard" \
    "$(reg_pats | grep -cE '^\*|^_\*$')" "0"
assert_ge "at least one group shares a glob, so it is not a name dump" \
    "$(reg_pats | grep -c '\*')" 3
assert_ge "and most entries are named individually" "$(reg_pats | grep -cv '\*')" 30
# A reason of one word would satisfy the format and still say nothing, so the
# floor is on length: the shortest real reason here is a phrase, not a label.
assert_ge "the shortest reason is a phrase" \
    "$(reg_why | awk 'BEGIN{m=0} { if (m == 0 || length($0) < m) m = length($0) } END { print m }')" 12
assert_no "no entry is a placeholder" "$reg_lines" "  TODO"

printf '\n== 11. it is wired up, and independent of the caller ==\n'
assert_has "run-all.sh discovers this suite, so CI runs the check" \
    "$(bash "$RUNALL" --list)" "tests/test-module-globals.sh"
cd "$TMPD" || exit 1
run_check cwd
assert_eq "works from another working directory" "0" "$RC"
run_check cwdlist --list
assert_eq "--list too" "0" "$RC"
cd "$REPO" || exit 1
assert_eq "and from a relative invocation" "0" "$(bash tools/check-module-globals.sh >/dev/null 2>&1; printf '%s' $?)"
run_check badarg --nonsense
assert_eq "an unknown argument is refused, not ignored" "2" "$RC"
run_check missing --register "$TMPD/no-such-file"
assert_eq "a missing register is an error, not a green run" "1" "$RC"
assert_has "and it says which file" "$missing" "no-such-file"

printf '\n== 12. the false claim is gone ==\n'
statedoc="$(cat -- "$STATE")"
assert_no "state.zsh no longer promises there are no standalone scalars" \
    "$statedoc" 'You will never see `_smart_some_thing=foo`'
assert_has "it states the real boundary instead" "$statedoc" "mutable RUNTIME STATE"
assert_has "and names the register it points at" "$statedoc" "Register: every _SMART_* global"
assert_has "the accessor doc says how to read on a hot path" \
    "$statedoc" "READING ON THE KEYSTROKE PATH"
assert_has "the sub-map doc was corrected to the real key name" \
    "$statedoc" "history.frequency      cmd -> occurrence count"
assert_no "and the key it used to claim is not documented any more" \
    "$statedoc" "history.freq "
assert_has "the live metadata sub-maps are documented now" "$statedoc" "history.cwd"
assert_no "the last_err slot nobody ever wrote is gone" "$statedoc" "last_err"

printf '\nMODULE-GLOBALS TOTAL PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
