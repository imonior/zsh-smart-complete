#!/usr/bin/env bash
# tests/run-all.sh
#
# Run the whole suite with one command, locally or in CI:
#
#     ./tests/run-all.sh                 # every suite, one line each
#     ./tests/run-all.sh -v              # ... with full output
#     ./tests/run-all.sh menu repaint    # only suites whose name matches
#     ./tests/run-all.sh --list          # what would run, then exit
#
# WHY THIS FILE EXISTS
#   The CI job used to list every suite by hand, and the comment next to that
#   list said the quiet part out loud: a new test file that nobody adds there is
#   silently never run. Discovery is the fix — tests/test-*.zsh runs under zsh,
#   tests/test-*.sh under bash, and anything else cannot hide.
#
# What is deliberately NOT discovered: tests/e2e-tmux.sh. It drives a real
# terminal through tmux and sleeps on wall-clock timings, so it is an advisory
# job in CI and a manual run locally, not part of the fast gate.

set -u

cd -- "$(dirname -- "$0")/.." || exit 1

VERBOSE=0
LIST_ONLY=0
FILTERS=()
for arg in "$@"; do
    case "$arg" in
        -v|--verbose) VERBOSE=1 ;;
        -l|--list)    LIST_ONLY=1 ;;
        -h|--help)    sed -n '2,16p' -- "$0"; exit 0 ;;
        -*)           printf 'run-all: unknown option %s (try --help)\n' "$arg" >&2; exit 2 ;;
        *)            FILTERS+=("$arg") ;;
    esac
done

# One "path<TAB>interpreter" entry per suite, in a stable order.
suites=()
for f in tests/test-*.zsh tests/test-*.sh; do
    [ -f "$f" ] || continue
    case "$f" in
        *.zsh) shells=(zsh) ;;
        *)     shells=(bash) ;;
    esac
    if [ "${#FILTERS[@]}" -gt 0 ]; then
        match=0
        for pat in "${FILTERS[@]}"; do
            case "$f" in *"$pat"*) match=1 ;; esac
        done
        [ "$match" -eq 1 ] || continue
    fi
    suites+=("$f|${shells[0]}")
done

if [ "$LIST_ONLY" -eq 1 ]; then
    for entry in "${suites[@]}"; do printf '%s\n' "${entry%|*}"; done
    exit 0
fi

if [ "${#suites[@]}" -eq 0 ]; then
    printf 'run-all: no suites matched (%s)\n' "${FILTERS[*]:-tests/test-*}" >&2
    exit 1
fi

# The suites print their tally in two shapes:
#   === TOTAL: 47 passed, 0 failed ===        (the zsh suites)
#   INSTALLER-OPTIONS TOTAL PASS=202 FAIL=0  (the bash suites)
# Summing them here means the assertion count quoted in README.md is a MEASURED
# number on every run instead of a hand-maintained claim that drifts.
total_pass=0
total_fail=0
failed_suites=()
ran=0

for entry in "${suites[@]}"; do
    f="${entry%|*}"
    shell="${entry##*|}"
    ran=$(( ran + 1 ))
    printf '%-34s' "$f"
    if out="$("$shell" "$f" 2>&1)"; then rc=0; else rc=1; fi
    tally="$(printf '%s\n' "$out" | grep -E 'TOTAL' | tail -n 1)"
    sp="$(printf '%s\n' "$out" | sed -n 's/.*TOTAL: \([0-9]\{1,\}\) passed.*/\1/p' | tail -n 1)"
    sf="$(printf '%s\n' "$out" | sed -n 's/.*TOTAL: [0-9]\{1,\} passed, \([0-9]\{1,\}\) failed.*/\1/p' | tail -n 1)"
    bp="$(printf '%s\n' "$out" | sed -n 's/.*TOTAL PASS=\([0-9]\{1,\}\).*/\1/p' | tail -n 1)"
    bf="$(printf '%s\n' "$out" | sed -n 's/.*TOTAL PASS=[0-9]\{1,\} FAIL=\([0-9]\{1,\}\).*/\1/p' | tail -n 1)"
    total_pass=$(( total_pass + ${sp:-0} + ${bp:-0} ))
    total_fail=$(( total_fail + ${sf:-0} + ${bf:-0} ))

    if [ "$rc" -eq 0 ]; then
        printf 'ok    %s\n' "${tally:-no tally reported}"
    else
        printf 'FAIL  rc=%s %s\n' "$rc" "${tally:-see output}"
        failed_suites+=("$f")
    fi
    if [ "$VERBOSE" -eq 1 ] || [ "$rc" -ne 0 ]; then
        printf '%s\n' "$out" | sed 's/^/      | /'
    fi
done

printf '\n'
printf 'run-all: %s suite(s), %s assertion(s) passed, %s failed\n' \
    "$ran" "$total_pass" "$total_fail"

if [ "${#failed_suites[@]}" -gt 0 ]; then
    printf 'run-all: FAILED suites: %s\n' "${failed_suites[*]}" >&2
    printf 'run-all: rerun one with e.g.  zsh tests/%s\n' \
        "$(basename -- "${failed_suites[0]}")" >&2
    exit 1
fi

if [ "$total_fail" -ne 0 ]; then
    # A suite that prints a FAIL count and still exits 0 is its own bug; catch it
    # here rather than shipping a green run that reported failures.
    printf 'run-all: exit status was 0 but %s assertion(s) failed\n' "$total_fail" >&2
    exit 1
fi

exit 0
