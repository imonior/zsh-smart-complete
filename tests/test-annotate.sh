#!/usr/bin/env bash
# tests/test-annotate.sh
#
# Checks tools/annotate.sh, the script that turns a `tests/run-all.sh -v` log into
# GitHub workflow annotations.
#
# WHY THIS SUITE EXISTS
#   The annotations are the only CI output readable without authentication, which
#   makes them the only evidence available when a container cell goes red and
#   nobody holding a token is looking. Twice now the diagnostic was the broken
#   part rather than the code: a `tail -n 5` over a broad grep named one failing
#   assertion out of seven, and a later packing joined the list and then cut it at
#   a fixed column, which does not truncate the annotation -- it truncates the
#   finding. A suite that tests a test-tool is unusual, so to be explicit about
#   what it does and does not buy:
#     * it proves the script reports every suite and every assertion the log holds
#     * it proves no annotation is emitted wider than the script's own budget, so
#       the folding cannot be silently defeated
#     * it does NOT prove anything about the cap GitHub applies. That limit is
#       assumed, not measured; WIDTH in the script is a knob, and if the real cap
#       turns out to be lower, the fix is to lower WIDTH and every assertion here
#       follows automatically.
#     * cost: one fixture log per scenario and a handful of greps. Milliseconds.
#   To withdraw it: rm tests/test-annotate.sh — run-all discovers suites, so no
#   other file mentions it.
#
# SECTION MAP
#   1  a green log: the total, one pair per suite, nothing at error level
#   2  a red log: every failing assertion survives, in name and in number
#   3  folding: long fields are split at entry boundaries, never trimmed
#   4  the two tally spellings, and a suite that reported neither
#   5  a missing or unreadable log says so and still exits 0
#   6  --failures: the same folding for a harness that is not run-all
#   7  it is wired into every job that needs it and decides no one's verdict

set -u

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ANNOTATE="$REPO/tools/annotate.sh"
RUNALL="$REPO/tests/run-all.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1" >&2; [ $# -gt 1 ] && printf '        %s\n' "$2" >&2; return 0; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then ok "$name"; else no "$name" "got=[$got] want=[$want]"; fi
}
assert_has() {
    local name="$1" hay="$2" needle="$3"
    if printf '%s\n' "$hay" | grep -qF -- "$needle"; then ok "$name"; else no "$name" "missing [$needle]"; fi
}
assert_not() {
    local name="$1" hay="$2" needle="$3"
    # An empty haystack passes every "not present" assertion, which is how a
    # wiring check ends up green while reading the wrong thing entirely.
    if [ -z "$hay" ]; then no "$name" "the haystack is empty, so nothing was read"; return; fi
    if printf '%s\n' "$hay" | grep -qF -- "$needle"; then no "$name" "found [$needle]"; else ok "$name"; fi
}

# Width the script itself declares, so the budget assertions below follow it
# instead of pinning a number that lives in the tool. No `--` before the path:
# BSD sed rejects it and this file has to run on macOS as well as on Linux.
WIDTH="$(sed -nE 's/^WIDTH=([0-9]+).*$/\1/p' "$ANNOTATE" | head -n 1)"
assert_ge_width() {
    local name="$1" got="$2" want="$3"
    if [ "$got" -ge "$want" ] 2>/dev/null; then ok "$name"; else no "$name" "[$got] < $want"; fi
}
assert_ge_width "the script declares a WIDTH" "${WIDTH:-0}" 40

# The budget is the tool's own WIDTH, so both bounds follow it: lower WIDTH in
# the script and these tighten on their own.
assert_le_width() {
    local name="$1" got="$2" want="$3"
    if [ "$got" -le "$want" ] 2>/dev/null; then ok "$name"; else no "$name" "[$got] > $want"; fi
}

run() { bash "$ANNOTATE" "$@"; }

# ---------------------------------------------------------------------------
# Fixture logs, in run-all's own shape: one summary line per suite at column
# zero, that suite's output indented with '| ' below it.
mk_green() {
    cat <<'EOF'
tests/test-alpha.zsh              ok    === TOTAL: 26 passed, 0 failed ===
      | === TOTAL: 26 passed, 0 failed ===
tests/test-beta.zsh               ok    === TOTAL: 4 passed, 0 failed ===
      | === TOTAL: 4 passed, 0 failed ===
tests/test-gamma.sh               ok    INSTALLER-GAMMA TOTAL PASS=375 FAIL=0
      | INSTALLER-GAMMA TOTAL PASS=375 FAIL=0

run-all: 3 suite(s), 405 assertion(s) passed, 0 failed
EOF
}

mk_red() {
    {
        printf '%s\n' 'tests/test-alpha.zsh              FAIL  rc=1 === TOTAL: 25 passed, 1 failed ==='
        printf '%s\n' '      | some other line about the fixture'
        printf '%s\n' '      | FAIL  the ghost is coloured  got=[none] want=[fg=110]'
        printf '%s\n' 'run-all: 1 suite(s), 25 assertion(s) passed, 1 failed'
        printf '%s\n' 'run-all: FAILED suites: test-alpha.zsh'
    }
}

# 16 assertions long enough that the joined list cannot fit one annotation.
mk_wide() {
    {
        printf '%s\n' 'tests/test-many.zsh               FAIL  rc=1 === TOTAL: 0 passed, 16 failed ==='
        for i in $(seq 1 16); do
            printf '      | FAIL  assertion %02d is a long enough name to matter got=[aaaaaaaaaaaaaaaaaaaa] want=[bbbbbbbbbbbbbbbbbbbb]\n' "$i"
        done
        printf '%s\n' 'run-all: 1 suite(s), 0 assertion(s) passed, 16 failed'
        printf '%s\n' 'run-all: FAILED suites: test-many.zsh'
    }
}

echo "== 1. a green log =="
GREEN="$TMP/green.log"; mk_green > "$GREEN"
out="$(run "$GREEN")"
assert_has "TOTAL carries run-all's own summary" "$out" "405 assertion(s) passed, 0 failed"
assert_has "zsh-shaped tally reduced to name:passed/failed" "$out" "test-alpha.zsh:26/0"
assert_has "installer-shaped tally reduced the same way"    "$out" "test-gamma.sh:375/0"
assert_has "and every suite in the log"                     "$out" "test-beta.zsh:4/0"
# Two annotations: run-all's summary line, and the three pairs, which fit one
# field. Counting them is the point — a packing that split each entry into its
# own annotation would blow the ~ten a check run shows.
assert_eq "one annotation per field, nothing folded" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2"
assert_not "a green run emits nothing at error level" "$out" "::error::"

echo "== 2. a red log =="
RED="$TMP/red.log"; mk_red > "$RED"
out="$(run "$RED")"
assert_has "the failing assertion is named, payload and all" "$out" "the ghost is coloured  got=[none] want=[fg=110]"
assert_has "the suite tally still rides, red or not"         "$out" "test-alpha.zsh:25/1"
assert_has "run-all's FAILED suites line survives"           "$out" "FAILED suites: test-alpha.zsh"
assert_eq  "the finding is published as an error" \
    "$(printf '%s\n' "$out" | grep -c '^::error::')" "1"

echo "== 3. folding =="
WIDE="$TMP/wide.log"; mk_wide > "$WIDE"
out="$(run "$WIDE")"
# Every one of the 16 must arrive. This is the regression the joined-and-cut
# version had: the list went out as ONE annotation of the full text, the platform
# truncated it, and the tail of the finding was simply gone.
missing=0
for i in $(seq -w 1 16); do
    printf '%s\n' "$out" | grep -qF "assertion $i" || missing=$((missing+1))
done
assert_eq "all 16 assertions arrive" "$missing" "0"
# The budget is measured on the tool's REAL bytes, with its own prefix stripped:
# asserting against a re-implementation of the packing would pass even if the
# script folded wrongly, which is the one thing this section is here to catch.
payloads="$(printf '%s\n' "$out" | sed -E 's/^::[a-z]+::[^:]*: //')"
longest="$(printf '%s\n' "$payloads" | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }')"
assert_le_width "no payload is wider than the declared budget" "$longest" "$WIDTH"
# 90 columns is what one cut entry costs, so anything above it can only be two
# entries sharing a field -- proof the folding packs rather than one-per-line,
# which is what would blow the ~ten annotations a check run shows.
assert_ge_width "and entries do share a field" "$longest" 91
# Split between entries, not inside them: an annotation that ends mid-name means
# the cut happened at a column.
assert_eq "no annotation ends mid-name" \
    "$(printf '%s\n' "$out" | grep -cE 'assertion [0-9]{2}$')" "0"
assert_ge_width "the 16 needed more than one annotation" \
    "$(printf '%s\n' "$out" | grep -c 'FAILING ASSERTIONS')" 2

echo "== 4. which suites show up =="
PART="$TMP/part.log"
{
    printf '%s\n' 'tests/test-quiet.zsh            ok    no tally reported'
    printf '%s\n' 'tests/test-loud.zsh             ok    === TOTAL: 2 passed, 0 failed ==='
    printf '%s\n' 'run-all: 2 suite(s), 2 assertion(s) passed, 0 failed'
} > "$PART"
out="$(run "$PART")"
assert_has "the suite that counted is listed"   "$out" "test-loud.zsh:2/0"
assert_not "the suite that did not is visible by being absent" "$out" "test-quiet.zsh"
assert_has "and its total still says two suites ran" "$out" "2 suite(s)"

echo "== 5. bad input =="
out="$(run "$TMP/does-not-exist.log")"; rc=$?
assert_has "a missing log says so in the channel it exists to feed" "$out" "no readable log"
assert_eq  "and still exits 0, because it is not the verdict" "$rc" "0"
: > "$TMP/empty.log"
out="$(run "$TMP/empty.log")"
assert_eq "an empty log annotates nothing" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"

echo "== 6. --failures: a harness that is not run-all =="
# The tmux end-to-end job's own log shape: `  FAIL  <name>` lines, a `SKIP:` line
# when tmux is absent, abort diagnostics at column zero, and quoted pane content
# indented four spaces. The step used to pack this with `tail -n 20` over a grep
# for FAIL|TOTAL|SKIP, which matched the pane quotes too -- so the slots filled
# with captured screen text and the failures were the part that got dropped.
E2E="$TMP/e2e.log"
{
    printf '%s\n' '  PASS  0 prompt appears'
    printf '%s\n' '  FAIL  12 the ghost keeps its colour'
    printf '%s\n' '    --- 12 screen ---'
    printf '%s\n' '    1:TOTAL whatever the pane happened to contain'
    printf '%s\n' '    2:FAIL: not a finding, just text on the screen'
    printf '%s\n' '  FAIL  13 one entry, not one per keystroke'
    printf '%s\n' 'FAIL: the harness zsh never rendered its prompt'
    printf '%s\n' 'E2E TOTAL PASS=1 FAIL=3'
} > "$E2E"
out="$(run --failures warning "E2E RESULT" '^[[:space:]]*(FAIL|SKIP)|E2E TOTAL' "$E2E")"; rc=$?
assert_has "a failure the harness names arrives"        "$out" "12 the ghost keeps its colour"
assert_has "so does one at column zero (an abort)"      "$out" "FAIL: the harness zsh never rendered its prompt"
assert_has "and the total, so the counts are readable"  "$out" "E2E TOTAL PASS=1 FAIL=3"
assert_not "text on the screen is not a failure"        "$out" "not a finding, just text on the screen"
assert_not "and a passing scenario is not reported"     "$out" "0 prompt appears"
assert_eq  "the harness's own indentation is stripped" \
    "$(printf '%s\n' "$out" | grep -c '  FAIL  ')" "0"
assert_eq  "advisory means warning level, not error"    "$(printf '%s\n' "$out" | grep -c '^::warning::E2E RESULT')" "1"
assert_eq  "and it still takes no verdict"              "$rc" "0"
out="$(run --failures warning "E2E RESULT" 'FAIL' "$TMP/nope.log")"; rc=$?
assert_has "an unreadable log says so"                  "$out" "--failures needs"
assert_eq  "and exits 0 like the rest of the script"    "$rc" "0"

echo "== 7. wiring =="
CI="$REPO/.github/workflows/ci.yml"
REL="$REPO/.github/workflows/release.yml"
CI_TEXT="$(cat "$CI")"
REL_TEXT="$(cat "$REL")"
# Every job that can go red without anyone holding a token, and only the calls --
# the comments name the script too, so count the invocations, not the mentions:
# three in ci.yml (test, zsh-versions, the advisory e2e run).
assert_eq "every ci.yml job runs it" \
    "$(grep -c '^[[:space:]]*bash tools/annotate\.sh' "$CI")" "3"
# The release gate checks out the TAGGED tree, where the script may not exist yet,
# so its call is guarded -- otherwise a release of an older tag fails on the
# diagnostic rather than on the code, which is the bug this whole script is for.
assert_has "the release gate runs it, guarded" "$REL_TEXT" '[ -f tools/annotate.sh ]'
assert_eq "and that is its one call" \
    "$(grep -c '^[[:space:]]*bash tools/annotate\.sh' "$REL")" "1"
assert_not "the joined-then-cut packing is gone from the workflow" "$CI_TEXT" "tr '\\n' ';'"
# Both tails that were the whole bug: a fixed number of lines over a broad grep,
# in which the summary always wins. Checked on the workflow's COMMANDS rather than
# its text, because the notes explaining why they went are the one place the old
# commands still appear -- and a grep over the file matched those notes first and
# made the assertion fail on the documentation of the fix.
CI_CODE="$(printf '%s\n' "$CI_TEXT" | grep -vE '^[[:space:]]*#')"
assert_not "so is the tail that named one failure out of seven" "$CI_CODE" "tail -n 5"
assert_not "and the e2e job's tail -n 20 is gone too" "$CI_CODE" "tail -n 20"
# Its own verdict: a diagnostic must never be what fails a build.
assert_not "the script reports problems, it does not raise them" \
    "$(grep -nE '^set ' "$ANNOTATE")" "set -e"

echo ""
echo "TOTAL PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
