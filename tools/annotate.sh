#!/usr/bin/env bash
#
# Turn a `tests/run-all.sh -v` log into GitHub workflow annotations.
#
#   tools/annotate.sh <log-file>
#   tools/annotate.sh --failures <level> <label> <ERE-pattern> <log-file>
#
# WHY THIS EXISTS
#   A CI failure nobody can read is not a signal, it is noise. Reading a job log
#   from outside the runner needs authentication; the annotations of its check run
#   do not (GET /repos/{owner}/{repo}/check-runs/{id}/annotations), so they are the
#   only channel available when a container cell goes red and nobody holding a
#   token is looking. Two things hid behind that: a red whose entire public
#   statement was ONE assertion name (it came from piping a broad grep into
#   `tail -n 5`, which kept the summary lines and dropped six of the seven
#   failures), and the assertion counts quoted in README.md and in release tags,
#   which could then only be checked by re-running the suite somewhere else.
#
# WHAT IT PUBLISHES
#   TOTAL              run-all's own summary line, green or red. This is the
#                      number the documentation quotes.
#   SUITE TALLIES      one `name:passed/failed` pair per suite, so a suite that
#                      disappeared from the list, or shrank, is visible rather
#                      than merely absent.
#   FAILING ASSERTIONS the text of every assertion the suites named, red runs
#                      only. Long entries are cut to 90 columns each: an
#                      assertion's name is the part that identifies it, and its
#                      got/want payload is in the log for whoever can read logs.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   It takes no verdict. The suite's exit code is the verdict and this script
#   always exits 0 -- a diagnostic that can fail a build is a second build system.
#   And it does not try to fit each field into one annotation: a check run
#   truncates a field at a few hundred characters and shows only about ten
#   annotations, so a field that does not fit is FOLDED into several annotations
#   instead of being trimmed. Half a list tells you less than all of it split in
#   two.
#
# The shape of the input is run-all's own (see tests/run-all.sh): one summary line
# per suite at column zero, and that suite's raw output indented with '| ' below
# it. The indent is what separates an assertion failure from run-all's own `FAIL
# rc=` line, and both are matched on purpose -- they say different things.

set -uo pipefail

# Target width of one annotation's payload. A check run truncates a field at a
# few hundred characters, so this is a tuning knob rather than a claim about the
# API: whatever it says, no entry is ever dropped or cut mid-name.
WIDTH=250

# chunk: read entries, one per line, and write them back grouped so that no
# output line is longer than WIDTH. Breaking between ENTRIES is the point: cut at
# a fixed column interleaves two assertion names inside two annotations, and
# neither is then readable.
chunk() {
    awk -v w="$WIDTH" -v sep="$1" '
        { if (buf == "") buf = $0
          else if (length(buf) + length(sep) + length($0) <= w) buf = buf sep $0
          else { print buf; buf = $0 } }
        END { if (buf != "") print buf }
    '
}

# emit <level> <label>: read pre-chunked lines and write one annotation each.
emit() {
    local level="$1" label="$2" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        printf '::%s::%s: %s\n' "$level" "$label" "$line"
    done
    return 0
}

# --failures <level> <label> <pattern> <log>: the same folding for a log that is
# not run-all's. The tmux end-to-end harness reports its own `  FAIL  <name>`
# lines, and its step used to pack them with `tail -n 20` over a grep that also
# matched every total -- which kept the summary and dropped the failures, the
# same loss this script exists to prevent. Sharing the folding is the point: a
# second copy is a second place to get it wrong.
if [[ "${1:-}" == "--failures" ]]; then
    level="${2:-}"; label="${3:-}"; pattern="${4:-}"; log="${5:-}"
    if [[ -z "$level" || -z "$label" || -z "$pattern" || ! -r "$log" ]]; then
        printf '::error::annotate: --failures needs <level> <label> <pattern> <readable-log>\n'
        exit 0
    fi
    # One entry per matching line, the harness's indentation removed, cut to 90
    # columns: the name is the part that identifies a failure.
    grep -E "$pattern" -- "$log" | sed -E 's/^[[:space:]]+//' | cut -c1-90 \
        | chunk ';' | emit "$level" "$label"
    exit 0
fi

LOG="${1:-}"
if [[ -z "$LOG" || ! -r "$LOG" ]]; then
    # Say so in the channel this script exists to feed, and still exit 0: the
    # suite's own status is the one that should decide the job.
    printf '::error::annotate: no readable log given (usage: tools/annotate.sh FILE)\n'
    exit 0
fi

# One line per suite, `name:passed/failed`, from run-all's own summary line. Two
# tally shapes exist because the suites are not all zsh: the shell suites print
# `=== TOTAL: N passed, M failed ===` and the installer ones print
# `TOTAL PASS=N FAIL=M`. A suite that printed neither is missing from the list --
# which is itself the report, because the count in TOTAL says how many ran.
#
# No `--` before the path: BSD sed rejects it, and this has to run on macOS too.
# The paths it is given are never option-shaped.
tallies() {
    sed -nE \
        -e 's#^tests/([^[:space:]]+).*=== TOTAL: ([0-9]+) passed, ([0-9]+) failed.*#\1:\2/\3#p' \
        -e 's#^tests/([^[:space:]]+).*TOTAL PASS=([0-9]+) FAIL=([0-9]+).*#\1:\2/\3#p' \
        "$1"
}

# Every assertion the suites reported, indented '| ' by run-all -v.
assertions() {
    grep -E '\|[[:space:]]+FAIL[[:space:]]' -- "$1" \
        | sed -E 's/^[[:space:]]*\|[[:space:]]+FAIL[[:space:]]+//; s/[[:space:]]+$//' \
        | cut -c1-90
}

# run-all's own summary, and its `FAILED suites:` line if there is one.
summary() {
    grep -E '^run-all:' -- "$1"
}

summary "$LOG"    | chunk ';' | emit notice "TOTAL"
tallies "$LOG"    | chunk ' ' | emit notice "SUITE TALLIES"
assertions "$LOG" | chunk ';' | emit error  "FAILING ASSERTIONS"

exit 0
