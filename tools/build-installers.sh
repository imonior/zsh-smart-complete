#!/usr/bin/env bash
#
# Splice lib/install/core.sh into the two installers.
#
#   tools/build-installers.sh           rewrite install.sh / install-entware.sh
#   tools/build-installers.sh --check   exit non-zero if they are not what the
#                                       generator would write, changing nothing
#
# Why a generator instead of a sourced file: both installers are things people
# pipe straight into bash (`curl -fsSL .../install.sh | bash`), so each has to
# stay self-contained. The shared part is therefore copied into them, and this
# script is what makes the copy a consequence of one file rather than something
# two edits can disagree about. CI runs --check, so a stale artifact fails the
# build the same way a stale build artifact would anywhere else.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
CORE="${ROOT}/lib/install/core.sh"

BEGIN='# >>> BEGIN generated block from lib/install/core.sh -- edit that file, run tools/build-installers.sh'
END='# <<< END generated block from lib/install/core.sh'

TARGETS=(install.sh install-entware.sh)

mode=write
case "${1:-}" in
    ''|--write) mode=write ;;
    --check)    mode=check ;;
    *)          printf 'usage: %s [--check]\n' "$0" >&2; exit 2 ;;
esac

[[ -f "$CORE" ]] || { printf 'missing %s\n' "$CORE" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rc=0
for target in "${TARGETS[@]}"; do
    src="${ROOT}/${target}"
    [[ -f "$src" ]] || { printf 'missing %s\n' "$src" >&2; exit 1; }
    out="${TMP}/${target}"

    awk -v begin="$BEGIN" -v end="$END" -v core="$CORE" -v file="$target" '
        index($0, begin) == 1 {
            if (seen) { print "second BEGIN marker in " file > "/dev/stderr"; bad = 1; exit }
            seen = 1
            print
            while ((getline line < core) > 0) print line
            close(core)
            skipping = 1
            next
        }
        skipping {
            if (index($0, end) == 1) { print; seen_end = 1; skipping = 0 }
            next
        }
        { print }
        END {
            if (bad) exit 3
            if (!seen)     { print "no generated-block markers in " file > "/dev/stderr"; exit 2 }
            if (!seen_end) { print "unterminated generated block in " file > "/dev/stderr"; exit 2 }
        }
    ' "$src" > "$out"

    if cmp -s "$src" "$out"; then
        printf '%-22s up to date (%s lines)\n' "$target" "$(wc -l < "$src" | tr -d ' ')"
    else
        printf '%-22s %s -> %s lines\n' "$target" "$(wc -l < "$src" | tr -d ' ')" "$(wc -l < "$out" | tr -d ' ')"
        if [[ "$mode" == write ]]; then
            cat "$out" > "$src"
            printf '%-22s rewritten from %s\n' "$target" "lib/install/core.sh"
        else
            printf '%-22s DIFFERS from %s: run tools/build-installers.sh and commit the result\n' \
                "$target" "lib/install/core.sh" >&2
            rc=1
        fi
    fi
done

exit "$rc"
