#!/usr/bin/env bash
# tests/test-installer-shared.sh
#
# The contract between install.sh and install-entware.sh, checked instead of
# assumed.
#
# WHY
#   The two installers are one file each, on purpose: README advertises
#   `curl -fsSL …/install.sh | bash`, so neither may source a sibling that the
#   pipe has not downloaded. Standalone-ness is the requirement that forces the
#   duplication — and duplication without a check is how the copies drifted: the
#   same string now lives under two different keys (`dl.clone_failed` in one,
#   `dl.clone_fallback` in the other), and `msg()` answers an unknown key by
#   printing the key itself, so a typo does not fail anything, it shows
#   `mirror.unavailable_line` in the user's terminal.
#
#   What is shared by agreement now lives in lib/install/core.sh and is spliced
#   into both installers by tools/build-installers.sh. That changes the question
#   this suite asks: not "do these two copies still agree" (they do, by
#   construction, and --check is what proves it) but "what is left outside the
#   generated block, and is it equal by accident or unequal on purpose".
#
#   The functions that stay duplicated AND divergent are the environment-specific
#   half — opkg paths, package names, the message catalog, the wording of a
#   question. Each is listed in allow_diverged with its reason, which turns a new
#   divergence into a failure instead of a quiet third way.
#
# NOT COVERED: keys built at runtime (they contain `$`), and `_msg` bodies that
# are never reached — an unreachable key is only dead weight, while an
# unreferenced call is what actually prints a raw key.

set -u

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO/install.sh"
ENTWARE="$REPO/install-entware.sh"
CORE="$REPO/lib/install/core.sh"
GEN="$REPO/tools/build-installers.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1" >&2; [ $# -gt 1 ] && printf '        %s\n' "$2" >&2; return 0; }

for f in "$INSTALL" "$ENTWARE"; do
    [ -f "$f" ] || { printf 'INSTALLER-SHARED TOTAL PASS=0 FAIL=1 SKIP (%s missing)\n' "$f"; exit 1; }
done

# Created here rather than per section: the parser lives in a file because a
# heredoc holding bash's own `<<<` and quote metacharacters cannot be nested
# inside a `$( … )` without bash reparsing it first.
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/zsc-shared.XXXXXX")" || TMPD=""
if [ -z "$TMPD" ]; then
    printf 'INSTALLER-SHARED TOTAL PASS=0 FAIL=1 SKIP (could not create a temp dir)\n'
    exit 1
fi
trap 'rm -rf -- "$TMPD"' EXIT

# Every catalog key defined by one file's _msg(), one per line.
catalog_keys() {
    awk '/^_msg\(\) \{/ { inc=1; next }
         inc && /^\}/     { inc=0 }
         inc' "$1" | grep -oE '^[[:space:]]+[a-z][a-z0-9_]*\.[a-z0-9_.]+\)' | tr -d ' )' | sort -u
}

# Every key one file asks msg() for, one per line. Keys with a `$` in them are
# assembled at runtime and cannot be resolved statically, so they are skipped.
used_keys() {
    grep -oE '\bmsg[[:space:]]+[a-z][a-z0-9_]*\.[a-z0-9_.]+' "$1" | awk '{print $2}' | sort -u
}

# Functions whose divergence is deliberate, each with the reason it is exempt.
# Anything shared that is NOT here and NOT identical fails the suite: the list is
# the debt register, and it only ever gets shorter.
allow_diverged() {
    cat <<'ALLOW'
_msg                                    catalogs hold different key sets today; unifying them is the dedup itself
_add_mirror                             entware records MIRROR_LABELS inline, install.sh derives them via _mirror_label
_apply_combo                            different combo keys (install.sh has four presets, entware has two outcomes)
_remove_omz                             install.sh removes a managed clone; entware only comments the loader out
_remove_p10k                            same, and entware has no ZDOTDIR to look in
_scan_other_rcs                         entware skips by basename because it does not track ZDOTDIR
_set_zsh_theme                          writes $HOME/.zshrc; install.sh writes $ZDOTDIR/.zshrc
_write_recommended_starship             entware cannot fetch templates, so the TOML is inlined
ask_smart_options                       different option sets (entware has no fzf-tab / no path menu)
build_zsc_integration                   different managed block (no zoxide, different loader path)
check_zsh                               entware installs zsh through opkg instead of aborting
clean_conflict_plugin                   different plugin roots to scan
comment_out_zshrc                       $HOME vs $ZDOTDIR
detect_env                              $HOME vs $ZDOTDIR
git_clone_repo                          different message key for the same event (see 1)
mirror_speed_test                       _mirror_label vs raw array, different unavailable key
prompt_yes                              install.sh clears REPLY first
resolve_omz_p10k                        different unknown-combo key and headless wording
run_with_mirror_dl                      `eval || return $?` vs `eval; return $?`
select_mirror                           _mirror_label vs raw array, auto_selected vs auto_fastest
zsc_prompt_snippet                      install.sh also initialises zoxide
ALLOW
}

echo ""
echo "=== 1. every key the installer asks for, its catalog defines ==="
for f in "$INSTALL" "$ENTWARE"; do
    name="$(basename -- "$f")"
    missing="$(comm -23 <(used_keys "$f") <(catalog_keys "$f"))"
    if [ -z "$missing" ]; then
        ok "$name: all referenced message keys exist"
    else
        no "$name: references keys its _msg() does not define" \
            "$(printf '%s' "$missing" | tr '\n' ' ') (msg() prints the raw key for these)"
    fi
done

echo ""
echo "=== 2. the lint is not vacuous ==="
# A check that cannot fail checks nothing. Both halves: a key that is used must
# be present above, and a key that is used WITHOUT being defined must be caught.
probe="$(mktemp "${TMPDIR:-/tmp}/zsc-shared-probe.XXXXXX")" || probe="/tmp/zsc-shared-probe.$$"
{
    echo 'LANG_CODE=en'
    echo '_msg() {'
    echo '    case "$1" in'
    echo '        real.key)'
    echo '            s="ok" ;;'
    echo '    esac'
    echo '    printf "%s" "$s"'
    echo '}'
    echo 'msg real.key'
    echo 'msg absent.key'
    echo '}'
} > "$probe"
caught="$(comm -23 <(used_keys "$probe") <(catalog_keys "$probe") | tr '\n' ' ')"
case "$caught" in
    *absent.key*) ok "an undefined key is reported (probe: $caught)" ;;
    *)            no "an undefined key is reported" "caught=[$caught]" ;;
esac
case " $caught " in
    *real.key*)   no "a defined key is not falsely reported" "caught=[$caught]" ;;
    *)            ok "a defined key is not falsely reported" ;;
esac
rm -f -- "$probe"

echo ""
echo "=== 3. the shared core reaches both artifacts, unchanged ==="

if [ ! -f "$CORE" ] || [ ! -f "$GEN" ]; then
    no "the shared core and its generator exist" "lib/install/core.sh or tools/build-installers.sh is missing"
else
    if bash -n "$CORE" 2>/dev/null; then
        ok "lib/install/core.sh parses on its own"
    else
        no "lib/install/core.sh parses on its own"
    fi
    # The check that makes most of what follows redundant when it holds: running
    # the generator writes exactly the bytes that are already committed. Both the
    # core and the artifacts are in the repository, so `curl | bash` never builds
    # anything — which is why a stale artifact is a real defect, not a cosmetic one.
    if out="$(bash "$GEN" --check 2>&1)"; then
        ok "both installers contain exactly what the generator writes"
    else
        no "both installers contain exactly what the generator writes" \
            "$(printf '%s\n' "$out" | awk '/DIFFERS/{print $1}' | tr '\n' ' ') is stale — run tools/build-installers.sh and commit it"
    fi
fi

# Function names and bodies come from one parser, shared with the comparison
# below, rather than from a regex over the whole file. Two shapes have to be
# handled: a one-line helper, and a body containing a heredoc — `_mk_dl_shim`
# writes a curl shim whose own `_zsc_rw() { … }` sits in column 0. Reading that
# as the end of the function would both invent a function and compare a
# truncated prefix, which is how two genuinely different shims look like
# agreement.
cat > "$TMPD/fns.py" <<'PY'
import io, re, sys

DEF = re.compile(r'^([A-Za-z_]\w*)\s*\(\)\s*\{')
ONE = re.compile(r'^[A-Za-z_]\w*\s*\(\)\s*\{.*\}\s*$')
HD = re.compile(r'<<(-?)[ \t]*(?:(["\'])([^"\'\s|&;<>()]+)\2|([^"\'\s|&;<>()]+))')
HSS = re.compile(r'<<-?[ \t]*<')          # `<<<` is a here-string, not a heredoc


def funcs(path):
    lines = [l.rstrip('\n') for l in io.open(path, encoding='utf-8', errors='replace')]
    heredoc, stack = [], []
    for line in lines:
        heredoc.append(bool(stack))
        if stack:
            body = line.lstrip('\t') if stack[0] == '-' else line
            if body == stack[1]:
                stack = []
            continue
        m = HD.search(HSS.sub('', line))
        if m:
            stack = [m.group(1) or '', m.group(3) or m.group(4)]
    out, i = {}, 0
    while i < len(lines):
        m = DEF.match(lines[i])
        if not m or heredoc[i] or lines[i][:1] in (' ', '\t'):
            i += 1
            continue
        start = i
        if ONE.match(lines[i]):
            end = i
        else:
            i += 1
            while i < len(lines) and not (lines[i] == '}' and not heredoc[i]):
                i += 1
            end = i
        out[m.group(1)] = lines[start:end + 1]
        i = end + 1
    return out


A, B, C = funcs(sys.argv[1]), funcs(sys.argv[2]), funcs(sys.argv[3])
for name in sorted(C):
    print('core\t%s' % name)
for name in sorted(set(A) & set(B)):
    print('%s\t%s' % ('same' if A[name] == B[name] else 'diff', name))
PY
if ! python3 "$TMPD/fns.py" "$INSTALL" "$ENTWARE" "$CORE" > "$TMPD/report" 2>"$TMPD/report.err"; then
    no "the function parser runs" "$(tail -n 2 "$TMPD/report.err" | tr '\n' ' ')"
fi

awk -F'\t' '$1=="core"{print $2}' "$TMPD/report" | sort > "$TMPD/core"
awk -F'\t' '$1=="same"{print $2}' "$TMPD/report" | sort > "$TMPD/identical"
awk -F'\t' '$1=="diff"{print $2}' "$TMPD/report" | sort > "$TMPD/diverged"
allow_diverged | awk 'NF{print $1}' | sort > "$TMPD/allow"

# The three lists below are only meaningful if the parser found something, so a
# zero here is a failure rather than an empty pass.
if [ ! -s "$TMPD/core" ] || [ ! -s "$TMPD/diverged" ]; then
    no "the parser found the functions it is asked about" \
        "core=$(wc -l < "$TMPD/core" | tr -d ' ') divergent=$(wc -l < "$TMPD/diverged" | tr -d ' ')"
else
    ok "$(wc -l < "$TMPD/core" | tr -d ' ') functions are shared through lib/install/core.sh"

    # Anything the core does not own that is nevertheless equal in both files
    # is duplicated by accident: it can drift tomorrow, and it belongs in the
    # core. Listing it keeps that queue visible instead of implicit.
    accidental="$(comm -13 "$TMPD/core" "$TMPD/identical" | tr '\n' ' ')"
    if [ -z "$accidental" ]; then
        ok "no identical function lives outside the shared core"
    else
        no "no identical function lives outside the shared core" \
            "duplicated by accident, and free to dedup: $accidental"
    fi
    # The other direction: a core name that is no longer identical between the
    # artifacts means a generated block was edited by hand.
    drifted="$(comm -23 "$TMPD/core" "$TMPD/identical" | tr '\n' ' ')"
    if [ -z "$drifted" ]; then
        ok "every core function is still byte-identical in both artifacts"
    else
        no "every core function is still byte-identical in both artifacts" \
            "hand-edited, or no longer defined by the core: $drifted"
    fi

    # A function defined twice is a function whose first definition is dead:
    # bash keeps the last one, so a copy left outside the marker boundary would
    # shadow the generated one with nothing visible to show for it.
    dups=""
    while IFS= read -r fn; do
        for f in "$INSTALL" "$ENTWARE"; do
            n="$(grep -c "^[[:space:]]*${fn}()[[:space:]]*{" "$f")"
            [ "$n" -eq 1 ] || dups="$dups $(basename -- "$f"):$fn=$n"
        done
    done < "$TMPD/core"
    if [ -z "$dups" ]; then
        ok "every core function is defined exactly once in each installer"
    else
        no "every core function is defined exactly once in each installer" "definitions:$dups"
    fi

    echo ""
    echo "=== 4. what is still duplicated and divergent is listed ==="

    unlisted="$(comm -23 "$TMPD/diverged" "$TMPD/allow" | tr '\n' ' ')"
    if [ -z "$unlisted" ]; then
        ok "$(wc -l < "$TMPD/diverged" | tr -d ' ') divergent shared functions are all on the recorded list"
    else
        no "$(wc -l < "$TMPD/diverged" | tr -d ' ') divergent shared functions are all on the recorded list" \
            "unrecorded: $unlisted — move it into lib/install/core.sh, or list it with its reason"
    fi

    # A name on the list that is no longer a divergent shared function — it moved
    # into the core, or one copy renamed it away — has to leave the list, or the
    # register drifts into something nobody can read.
    stale="$(comm -23 "$TMPD/allow" "$TMPD/diverged" | tr '\n' ' ')"
    if [ -z "$stale" ]; then
        ok "no listed divergence refers to a function that is not divergent"
    else
        no "no listed divergence refers to a function that is not divergent" "stale: $stale"
    fi
    # Something on the debt register that has become identical again goes into the
    # core or off the list; either way it stops being debt.
    both="$(comm -12 "$TMPD/identical" "$TMPD/allow" | tr '\n' ' ')"
    if [ -z "$both" ]; then
        ok "no function on the divergence list is identical again"
    else
        no "no function on the divergence list is identical again" "into the core with it: $both"
    fi
fi

echo ""
printf 'INSTALLER-SHARED TOTAL PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
