#!/usr/bin/env bash
#
# Check that every module-level `_SMART_*` global is justified in the register.
#
#   tools/check-module-globals.sh                  check the tree, exit 1 on a problem
#   tools/check-module-globals.sh --list           print the catalog, no verdict
#   tools/check-module-globals.sh --register FILE  read the register from FILE
#   tools/check-module-globals.sh --source FILE    replace the scanned sources
#                                                  (repeatable; used by the tests)
#
# WHY THIS EXISTS
#   lib/state.zsh claimed to be the only place mutable runtime data lives, and
#   named "the 37 unrelated global scalars" as the rot it prevents -- while the
#   tree carries global declarations of its own outside it. Either the rule is
#   true or those are; a comment that both asserts a rule and is contradicted by
#   the code is worse than no comment, because the next reader trusts it. So the
#   rule now says what it really means (runtime STATE belongs in the container,
#   anything else needs a reason), and the register at the bottom of
#   lib/state.zsh is where that reason gets written down. This script is what
#   makes skipping that step a failure instead of a silent drift.
#
# THE TWO DIRECTIONS IT CHECKS
#   UNDECLARED  a global no register line matches: new state without a reason.
#   STALE       a register line no global matches: a name that moved or died,
#               which would otherwise leave the register describing a codebase
#               that no longer exists.
#
# WHAT IT DELIBERATELY DOES NOT MATCH
#   Tunables written as `: ${_SMART_W_PREFIX:=400}` (lib/engine/ranking.zsh and
#   friends). Those are env-overridable configuration with a private alias and
#   are never assigned again, so they are not state. The scan is
#   declaration-shaped for the same reason: it looks for `typeset -g…` and for
#   bare assignments, not for every appearance of a name.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
REGISTER="${ROOT}/lib/state.zsh"

mode=check
sources=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)     mode=list; shift ;;
        --register) shift
                    [[ $# -gt 0 ]] || { printf -- '--register needs a file\n' >&2; exit 2; }
                    REGISTER="$1"; shift ;;
        --source)   shift
                    [[ $# -gt 0 ]] || { printf -- '--source needs a file\n' >&2; exit 2; }
                    sources+=("$1"); shift ;;
        -h|--help)  sed -n '2,37p' -- "$0"; exit 0 ;;
        *)          printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[[ -r "$REGISTER" ]] || { printf 'missing register file: %s\n' "$REGISTER" >&2; exit 1; }

if [[ "${#sources[@]}" -eq 0 ]]; then
    for f in "${ROOT}"/lib/*.zsh "${ROOT}"/lib/*/*.zsh "${ROOT}/zsh-smart-complete.plugin.zsh"; do
        if [[ -f "$f" ]]; then sources+=("$f"); fi
    done
fi
[[ "${#sources[@]}" -gt 0 ]] || { printf 'no sources to scan\n' >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null' EXIT

# ---------------------------------------------------------------------------
# 1. declarations
#
# Two shapes, because zsh gives you both:
#   typeset -g / -gA / -ga / -gi / -gaU NAME   ANYWHERE in the file. A `-g`
#     inside a function body is exactly as global as one at the top, and
#     _SMART_BUILD_* is deliberately declared that way.
#   NAME=… or NAME[k]=…                        an assignment with no typeset at
#     all. Indentation is ignored on purpose: a bare assignment inside a
#     function still creates a global, which is precisely the accident worth
#     catching.
# Each match is one SITE; a name written from three places is one NAME. The
# fourth field records WHICH rule found it, because a name that only ever shows
# up under the second rule was never declared at all.
# ---------------------------------------------------------------------------
awk '
    function emit(n, kind) { if (n ~ /^_SMART[A-Za-z0-9_]*$/) print n "\t" FILENAME "\t" FNR "\t" kind }
    {
        line = $0
        if (match(line, /^[ \t]*typeset[ \t]+-g[a-zA-Z]*[ \t]+/)) {
            rest = substr(line, RSTART + RLENGTH)
            while (match(rest, /^[a-zA-Z_-]+[ \t]+/)) rest = substr(rest, RLENGTH + 1)
            n = split(rest, parts, /[ \t]+/)
            for (i = 1; i <= n; i++) { nm = parts[i]; sub(/[ \t]*=.*/, "", nm); emit(nm, "T") }
            next
        }
        if (match(line, /^[ \t]*_SMART[A-Za-z0-9_]*([[][^\]]*\])?[ \t]*=/)) {
            nm = substr(line, RSTART, RLENGTH)
            sub(/[ \t]*=.*/, "", nm)
            sub(/\[.*$/, "", nm)
            sub(/^[ \t]*/, "", nm)
            emit(nm, "A")
        }
    }
' "${sources[@]}" > "$TMP/sites"
sort -u "$TMP/sites" > "$TMP/sites.uniq"
cut -f1 -- "$TMP/sites" | sort -u > "$TMP/names"
# One line per NAME, pointing at the first of what may be several sites, and
# carrying T if ANY site declared it (a name whose every site is an assignment
# was never declared at all -- see the IMPLICIT check below).
awk -F'\t' '
    {
        if ($4 == "T") typed[$1] = 1
        if (!($1 in where)) { where[$1] = $2 "\t" $3 }
    }
    END {
        for (n in where) printf "%s\t%s\t%s\n", n, where[n], (n in typed ? "T" : "A")
    }
' "$TMP/sites.uniq" | sort > "$TMP/names.first"

# ---------------------------------------------------------------------------
# 2. the register
#
# `# GLOBAL: <name-or-glob>  <reason>` — one entry per line, and the reason is
# separated by TWO OR MORE spaces, which is what lets the parser tell a pattern
# from prose without a delimiter. A line that puts one space there reports as
# having no reason: the register's whole value is the reason, so the format
# insists on it. Globs (`_SMART_EVT_ORIG_*`) carry the groups where every member
# shares one lifecycle; naming the rest individually is the point.
# ---------------------------------------------------------------------------
awk '
    /^# GLOBAL:/ {
        entry = substr($0, 10)
        sub(/^[ \t]+/, "", entry)
        pat = entry
        sub(/[ \t].*$/, "", pat)
        reason = ""
        if (entry != pat && match(entry, /^[^ \t]+[ \t][ \t]+/)) {
            reason = substr(entry, RLENGTH + 1)
            sub(/^[ \t]+/, "", reason)
        }
        if (pat != "") print pat "\t" reason
    }
' "$REGISTER" > "$TMP/register"

cut -f1 -- "$TMP/register" | sort -u > "$TMP/patterns"
name_count="$(wc -l < "$TMP/names" | tr -d ' ')"
site_count="$(wc -l < "$TMP/sites.uniq" | tr -d ' ')"
pattern_count="$(wc -l < "$TMP/patterns" | tr -d ' ')"

if [[ "$mode" == list ]]; then
    printf 'module-globals: %s name(s) in %s declaration site(s), %s register pattern(s)\n\n' \
        "$name_count" "$site_count" "$pattern_count"
    printf '%-32s %s\n' NAME 'DECLARED AT'
    while IFS=$'\t' read -r name file line kind; do
        printf '%-32s %s:%s%s\n' "$name" "${file#"$ROOT"/}" "$line" \
            "$([[ "$kind" == A ]] && printf '  (assigned, not declared)')"
    done < "$TMP/names.first"
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. both directions
# ---------------------------------------------------------------------------
rc=0
: > "$TMP/hits"
while IFS= read -r name; do
    hit=""
    while IFS= read -r pat; do
        [[ -n "$pat" ]] || continue
        # shellcheck disable=SC2254
        case "$name" in $pat) hit="$pat"; break ;; esac
    done < "$TMP/patterns"
    if [[ -z "$hit" ]]; then
        where="$(awk -F'\t' -v n="$name" '$1==n { printf "%s:%s", $2, $3; exit }' "$TMP/sites")"
        printf 'UNDECLARED  %-32s %s\n' "$name" "${where#"$ROOT"/}"
        rc=1
    else
        printf '%s\n' "$hit" >> "$TMP/hits"
    fi
done < "$TMP/names"

while IFS= read -r pat; do
    [[ -n "$pat" ]] || continue
    if ! grep -qxF -- "$pat" "$TMP/hits"; then
        printf 'STALE       %-32s no declaration matches this # GLOBAL: line\n' "$pat"
        rc=1
    fi
done < "$TMP/patterns"

while IFS=$'\t' read -r pat reason; do
    if [[ -z "$reason" ]]; then
        printf 'NO REASON   %-32s a # GLOBAL: line has to say why\n' "$pat"
        rc=1
    fi
done < "$TMP/register"

# ---------------------------------------------------------------------------
# 4. a global that is only ever assigned
#
# `no_warn_create_global` is on in every module, so the first write to an
# undeclared name silently makes it a global. That is how two of the names in
# this codebase existed: reachable, registered, and nowhere declaring itself —
# which is also how a name disappears from an audit that reads declarations.
# ---------------------------------------------------------------------------
while IFS=$'\t' read -r name file line kind; do
    if [[ "$kind" == A ]]; then
        printf 'IMPLICIT    %-32s assigned at %s:%s but never declared with `typeset -g`\n' \
            "$name" "${file#"$ROOT"/}" "$line"
        rc=1
    fi
done < "$TMP/names.first"

# ---------------------------------------------------------------------------
# 5. the container's own key list, checked the same way
#
# The "Canonical keys / sub-maps / lists" blocks are a contract too — they are
# what a port to another language reads first. Two entries had drifted from the
# code there (a `history.freq` for a map named `history.frequency`, and a
# `history.first_char` that nothing wrote), which is exactly how a document that
# claims to be a spec fails. So every documented key has to be used by something
# in the scanned sources.
#
# The reverse direction — a key in use but missing from the doc — is NOT checked,
# because keys travel as variables (`_smart_state_l_set "$sub"`), so a literal
# scan of the code cannot tell a real gap from a dynamic call.
# ---------------------------------------------------------------------------
awk '
    /^# Canonical[ \t]/ { inblock = 1; next }
    inblock && /^[ \t]*$/ { inblock = 0 }
    inblock && /^#[ \t]{3}[a-z_][a-z0-9_.]*[ \t]{2,}/ {
        k = substr($0, 5)
        sub(/[ \t].*$/, "", k)
        print k
    }
' "$REGISTER" | sort -u > "$TMP/dockeys"

while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    re="$(printf '%s' "$key" | sed 's/\./\\./g')"
    if ! grep -qE "(_SMART_STATE(_A|_L)?\[\"?'?${re}[])])|(_smart_state_[a-z_]+[[:space:]]+[\"']?${re}[\"'[[:space:]])" \
            "${sources[@]}"; then
        printf 'DEAD KEY    %-32s documented as a state key, used by nothing\n' "$key"
        rc=1
    fi
done < "$TMP/dockeys"

doc_count="$(wc -l < "$TMP/dockeys" | tr -d ' ')"
printf 'module-globals: %s name(s) in %s declaration site(s), %s register pattern(s), %s documented key(s), %s\n' \
    "$name_count" "$site_count" "$pattern_count" "$doc_count" \
    "$([[ $rc -eq 0 ]] && printf 'all covered' || printf 'PROBLEMS (see above)')"
exit "$rc"
