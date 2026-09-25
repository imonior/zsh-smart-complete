#!/usr/bin/env bash
# tests/test-installer-sandbox.sh
#
# RUN the installers end to end, in a sandbox, and read what they print.
#
# WHY THIS EXISTS
#   Everything else in tests/ either sources a lib/*.zsh module or extracts a
#   single function out of install.sh (test-installer-options.sh) and drives it
#   against a fixture. Neither of those can see the installer as a whole: not
#   the code that wires the functions together, not the order they run in, not
#   that the file is executed by BASH. That is how `print -r --` — a zsh
#   builtin — sat in install.sh's settings-file fallback through a release:
#   on a machine with no `print` on PATH the installer exited 127 at its last
#   step, after a .zshrc had already been rewritten, and left an empty
#   settings file that the `[[ ! -f ]]` guard then refused to touch forever.
#
#   It is also the only proof that `set -u` is safe to have on. An installer
#   aborting halfway is worse than an unset variable expanding to nothing, so
#   the flag is only honest while something actually walks these branches.
#
# HOW IT STAYS SANDBOXED
#   `env -i` (no inherited environment), HOME/ZDOTDIR/XDG_* inside a fresh
#   mktemp -d, and a PATH that contains ONLY what this file puts there: a stub
#   dir for the network and package tools, and a symlink farm of the core
#   utilities the installers legitimately need. Each stub appends its arguments
#   to a log instead of doing anything, so a run that tried to escape the
#   sandbox would show up as a line in that log — asserted below.
#
#   The farm is an ALLOWLIST, and that is the part that matters. Appending the
#   real /usr/bin "for date and awk" makes the run a sample of the machine it
#   happens to execute on: the installers decide what to install, and which
#   config-write branch to take, by asking `command -v` for fzf, starship,
#   atuin, zoxide and zinit. A runner image that ships one of those then
#   asserts a different .zshrc than a clean laptop did — which is how one commit
#   came to be green on macOS and red on ubuntu. Names outside the list are
#   absent on EVERY host, so those probes answer "not installed" everywhere.
#
# TALLY: prints "INSTALLER-SANDBOX TOTAL PASS=n FAIL=m" like the other bash
# suite does, because tests/run-all.sh discovers this file by name and sums both
# shapes.

set -u

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO/install.sh"
ENTWARE="$REPO/install-entware.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1" >&2; [ $# -gt 1 ] && printf '        %s\n' "$2" >&2; return 0; }
check() { # check <label> <want> <got>
    if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want=[$2] got=[$3]"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zsc-installer-sandbox.XXXXXX")" || {
    echo "INSTALLER-SANDBOX TOTAL PASS=0 FAIL=0 SKIP (mktemp failed)"
    exit 0
}
trap 'rm -rf -- "$TMP"' EXIT

# --- the stub bin dir ------------------------------------------------------
# `sudo` is in here with the package tools, not in the core farm below: a run
# that could escalate would not be sandboxed no matter how empty its PATH is,
# and the linux-debian branch of install_pkg_soft calls it directly.
BIN="$TMP/bin"; mkdir -p "$BIN"
STUB_LOG="$TMP/stubs.log"; : > "$STUB_LOG"
for c in curl wget git brew apt apt-get opkg chsh stow sudo; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 0\n' "$c" "$STUB_LOG" > "$BIN/$c"
    chmod +x "$BIN/$c"
done

# --- the core farm: the only other thing a run is allowed to see ------------
# Resolved from THIS shell's PATH once, into symlinks, so a run gets a fixed
# tool inventory rather than the host's. A name that does not resolve is a hard
# error, not a silent gap — a missing coreutil inside the sandbox would look
# exactly like a defect in the installer.
#
# What is deliberately NOT here: `timeout` (macOS ships no such binary, so every
# run takes the branch without it, which is the branch a macOS user gets), and
# fzf / starship / atuin / zoxide / zinit, whose presence the installers probe to
# decide what to install and which config-write branch to take.
CORE="$TMP/core"; mkdir -p "$CORE"
_missing=""
for c in sh bash zsh awk sed grep mktemp cp mv rm cat touch chmod mkdir rmdir \
         ln readlink basename dirname find sort head tail tr wc cut uniq date \
         uname id whoami tty stty sleep expr diff xargs env ls pwd du ps kill; do
    src="$(command -v "$c" 2>/dev/null)" || src=""
    if [ -n "$src" ]; then
        ln -s "$src" "$CORE/$c"
    else
        _missing="$_missing $c"
    fi
done
if [ -n "$_missing" ]; then
    printf '  FAIL  this host has no:%s — the suite cannot promise a fixed tool inventory\n' "$_missing" >&2
    printf 'INSTALLER-SANDBOX TOTAL PASS=0 FAIL=1\n'
    exit 1
fi

# A run is: fresh $HOME, no inherited environment, stubs on PATH, and the
# documented knobs on the command line. $1 = label, rest = NAME=value pairs.
#
# The exit code lands in "$TMP/$label.rc" rather than in a shell variable named
# after the label: labels legitimately contain dashes (lang_zh-CN,
# combo_zinit-starship), and `eval "$label""_rc=$?"` with such a label stops
# being an assignment and becomes a command lookup that silently overwrites $?.
# Two dash-free options were considered and rejected — a parallel array of
# labels needs a linear scan per read, and `declare -A` is a bash 4 feature we
# cannot assume here (macOS still ships 3.2).
run_installer() {
    label="$1"; shift
    home="$TMP/h_$label"
    mkdir -p "$home"
    # A section that cares what the user's config looked like BEFORE the install
    # drops a seed file at $TMP/<label>.seed; everyone else keeps getting the
    # empty one, which is what "first run on a fresh account" means.
    if [ -f "$TMP/$label.seed" ]; then cp "$TMP/$label.seed" "$home/.zshrc"; else : > "$home/.zshrc"; fi
    : > "$STUB_LOG"
    # `date`, `awk`, `sed`, `grep` and `bash` itself come from the core farm,
    # which is the whole rest of the world this run can address.
    env -i PATH="$BIN:$CORE" \
        HOME="$home" ZDOTDIR="$home" \
        XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
        TERM="${TERM:-dumb}" TMPDIR="${TMPDIR:-/tmp}" \
        "$@" \
        bash "$INSTALL" > "$TMP/$label.out" 2>&1
    printf '%s' "$?" > "$TMP/$label.rc"
    # Snapshot the calls this one run made: $STUB_LOG is truncated per run, so a
    # later section that wants to ask "did the mirror knob reach git clone?" has
    # to read the copy, not the live log (which by then holds only the last run).
    cp "$STUB_LOG" "$TMP/$label.stubs.log"
}

# $1 = label, $2 = expected exit code (0 unless a failure is the point)
assert_run() {
    label="$1"; want="${2:-0}"
    if [ ! -f "$TMP/$label.rc" ]; then
        no "$label: exit code" "run_installer never recorded $TMP/$label.rc"
        return 0
    fi
    check "$label: exit code" "$want" "$(cat "$TMP/$label.rc")"
    out_file="$TMP/$label.out"
    if grep -q "unbound variable" "$out_file"; then
        no "$label: no unbound variable under set -u" "$(grep -m1 'unbound variable' "$out_file")"
    else
        ok "$label: no unbound variable under set -u"
    fi
    if grep -qE "command not found" "$out_file"; then
        no "$label: no missing command (a zsh-ism in bash?)" "$(grep -m1 'command not found' "$out_file")"
    else
        ok "$label: no missing command (a zsh-ism in bash?)"
    fi
}

# What an install must have LEFT BEHIND.
#
# The evidence for a missing block goes INSIDE the FAIL line rather than on the
# detail line under it: this suite's CI log is behind authentication, the
# annotations of a check run are not, and only a reported line reaches an
# annotation. The counts are structural facts; the two greps name the branch the
# config writer took, and are safe to match in English because every label that
# reaches this function pins SMART_INSTALL_LANG=en.
_installed_evidence() {
    label="$1"; home="$TMP/h_$label"
    printf 'rc=%s size=%s opts=%s integ=%s baks=%s ph0=%s branch=%s last=%s' \
        "$(cat "$TMP/$label.rc" 2>/dev/null)" \
        "$(wc -c < "$home/.zshrc" 2>/dev/null | tr -d ' ')" \
        "$(grep -c '>>> zsh-smart-complete options (managed) >>>' "$home/.zshrc" 2>/dev/null)" \
        "$(grep -c '>>> zsh-smart-complete integration (managed) >>>' "$home/.zshrc" 2>/dev/null)" \
        "$(find "$home" -maxdepth 1 -name '.zshrc.bak.*' 2>/dev/null | wc -l | tr -d ' ')" \
        "$(grep -c 'Phase 0/5' "$TMP/$label.out" 2>/dev/null)" \
        "$(grep -oE 'No ~/\.zshrc found|created with the zsh-smart-complete integration block|Plugin-only install|config already present|created with the recommended full-stack|replaced with the recommended full-stack|block refreshed|updated with the integration block' \
              "$TMP/$label.out" 2>/dev/null | sort -u | tr '\n' '+')" \
        "$(grep -v '^[[:space:]]*$' "$TMP/$label.out" 2>/dev/null | tail -1 | tr -d '\n' | cut -c1-60)"
}
assert_installed() {
    label="$1"
    home="$TMP/h_$label"
    if grep -q ">>> zsh-smart-complete options (managed) >>>" "$home/.zshrc"; then
        ok "$label: managed options block written to .zshrc"
    else
        no "$label: managed options block written to .zshrc -- $(_installed_evidence "$label")"
    fi
    if grep -q ">>> zsh-smart-complete integration (managed) >>>" "$home/.zshrc"; then
        ok "$label: integration block written to .zshrc"
    else
        no "$label: integration block written to .zshrc -- $(_installed_evidence "$label")"
    fi
    settings="$home/.config/zsh-smart-complete/settings.zsh"
    # The bug this file was written for: the fallback writer ran a zsh builtin,
    # so this file existed but was EMPTY, and an empty file also made the
    # "only create if absent" guard refuse to ever fix it.
    if [ -s "$settings" ] && grep -q "SMART_MENU" "$settings"; then
        ok "$label: settings starter file is non-empty"
    else
        no "$label: settings starter file is non-empty" "size=$(wc -c < "$settings" 2>/dev/null || echo missing)"
    fi
}

echo ""
echo "=== 1. NONINTERACTIVE defaults (the CI / headless path) ==="
[ -f "$INSTALL" ] || { echo "INSTALLER-SANDBOX TOTAL PASS=0 FAIL=1 SKIP (install.sh missing)"; exit 1; }
run_installer defaults NONINTERACTIVE=1 SKIP_DEPS=1 SMART_INSTALL_LANG=en
assert_run defaults 0
assert_installed defaults

echo ""
echo "=== 2. the documented combo presets ==="
for combo in zinit-starship zinit-p10k keep-omz not-a-combo; do
    run_installer "combo_$combo" NONINTERACTIVE=1 SKIP_DEPS=1 "SMART_INSTALL_COMBO=$combo"
    assert_run "combo_$combo" 0
done

echo ""
echo "=== 3. every documented UI language ==="
for lang in en zh-CN zh-TW ja ko; do
    run_installer "lang_$lang" NONINTERACTIVE=1 SKIP_DEPS=1 "SMART_INSTALL_LANG=$lang"
    assert_run "lang_$lang" 0
done

echo ""
echo "=== 4. the network branches, with the downloaders stubbed ==="
# Without SKIP_DEPS the installer runs its mirror speed test, sorts the
# candidates, installs starship/atuin through `curl | sh` and clones with git.
# Every one of those goes through a stub that returns nothing, which is the
# worst case for the code that reads their results: an empty timing table, an
# empty clone directory, a starship binary that never appeared. This is what
# exercises the MIRROR_TIMES lookups and the settings-file fallback.
# Per-run stub-call snapshots live in "$TMP/<label>.stubs.log"; the live log is
# truncated by the next run.
run_installer net_no_skipping NONINTERACTIVE=1 SMART_INSTALL_LANG=en
assert_run net_no_skipping 0
assert_installed net_no_skipping
# A prefix-type mirror (SMART_INSTALL_GH_MIRROR starting with https://) is
# concatenated in front of the github.com URL, so the rewritten clone target is
# observable in the stub log — the only way to check the knob did something
# without a network.
run_installer net_mirror NONINTERACTIVE=1 SMART_INSTALL_LANG=zh-CN \
    SMART_INSTALL_GH_MIRROR="https://gh.example/"
assert_run net_mirror 0

echo ""
echo "=== 5. nothing tried to leave the sandbox ==="
# The stubs log every call. A real network tool reached by ABSOLUTE path would
# NOT appear here, which is the one hole this check cannot cover; everything the
# installers reach by name is either a stub or a symlink this file made.
if grep -qE '^curl( |$)' "$TMP/net_no_skipping.stubs.log"; then
    ok "the downloader stubs were exercised (so branch 4 was real)"
else
    no "the downloader stubs were exercised (so branch 4 was real)" \
        "$(cat "$TMP/net_no_skipping.stubs.log")"
fi
# The mirror speed test is the one code path that calls curl with a timeout. If
# it never ran, section 4 tested the SKIP_DEPS branch twice and the MIRROR_TIMES
# reads stay uncovered.
if grep -qF -- '--connect-timeout' "$TMP/net_no_skipping.stubs.log"; then
    ok "the no-SKIP_DEPS run reached the mirror speed test"
else
    no "the no-SKIP_DEPS run reached the mirror speed test" \
        "$(cat "$TMP/net_no_skipping.stubs.log")"
fi
if grep -qF -- 'https://gh.example/https://github.com/' "$TMP/net_mirror.stubs.log"; then
    ok "SMART_INSTALL_GH_MIRROR rewrote the clone URL"
else
    no "SMART_INSTALL_GH_MIRROR rewrote the clone URL" \
        "$(cat "$TMP/net_mirror.stubs.log")"
fi

# The witness for the allowlist: the probes that used to answer "whatever this
# machine has" now answer the same way on every machine. Both halves are
# asserted, because an empty farm would satisfy the first half for free.
for c in fzf starship atuin zoxide zinit; do
    if env -i PATH="$BIN:$CORE" sh -c "command -v $c" >/dev/null 2>&1; then
        no "the sandbox cannot see $c, so that probe is not a host sample"
    else
        ok "the sandbox cannot see $c, so that probe is not a host sample"
    fi
done
if env -i PATH="$BIN:$CORE" sh -c \
        'command -v awk >/dev/null && command -v mktemp >/dev/null && command -v mv >/dev/null && command -v zsh >/dev/null'; then
    ok "and it can see the tools the installers actually call"
else
    no "and it can see the tools the installers actually call" \
       "farm: $(ls "$CORE" | tr '\n' ' ')"
fi

echo ""
echo "=== 6. the entware installer reaches its own guard, cleanly ==="
# The script decides "am I on Entware" with `command -v opkg`, so the opkg stub
# has to be absent for this branch to be reachable — with $BIN on PATH it
# happily "detects Entware", installs against a stub and rewrites .zshrc, which
# asserts nothing we can trust (a real opkg has feeds, a root and a /opt). Copy
# the other stubs in: any downloader it does reach must still be logged rather
# than missed. This guard path is the only part of install-entware.sh reachable
# on a normal machine, and it still proves the shared preamble runs under -u.
BIN_ENT="$TMP/bin-no-opkg"; mkdir -p "$BIN_ENT"
for c in "$BIN"/*; do
    [ "$(basename -- "$c")" = opkg ] && continue
    cp "$c" "$BIN_ENT/"
done
ehome="$TMP/h_entware"; mkdir -p "$ehome"; : > "$ehome/.zshrc"
: > "$STUB_LOG"
env -i PATH="$BIN_ENT:$CORE" HOME="$ehome" ZDOTDIR="$ehome" \
    TERM=dumb NONINTERACTIVE=1 bash "$ENTWARE" > "$TMP/entware.out" 2>&1
ent_rc=$?
check "entware: refuses without opkg (exit 1)" "1" "$ent_rc"
if grep -q "unbound variable" "$TMP/entware.out"; then
    no "entware: no unbound variable before the guard" "$(grep -m1 'unbound variable' "$TMP/entware.out")"
else
    ok "entware: no unbound variable before the guard"
fi
if grep -q "command not found" "$TMP/entware.out"; then
    no "entware: no missing command before the guard" "$(grep -m1 'command not found' "$TMP/entware.out")"
else
    ok "entware: no missing command before the guard"
fi
check "entware: left .zshrc alone" "0" "$(wc -c < "$ehome/.zshrc" | tr -d ' ')"

echo ""
echo "=== 7. no zsh-only syntax in a bash script ==="
# The class of bug behind section 1, checked at the source instead of by
# running every branch: `print -r` writes nothing in bash and is not a file on
# disk either, so it is exit 127 the moment a machine lacks a program named
# "print". ${(f)}, $+array[x] and setopt are zsh-only for the same reason.
#
# These scripts also EMBED zsh — .zshrc and settings templates arrive as
# heredoc bodies, and those lines are supposed to be zsh. So grep the code and
# not the payloads: blank out every heredoc body first (the line count is kept,
# so a reported line number still points at the file), otherwise
# `setopt appendhistory` inside a written template reads as a bug.
bash_code_only() {
    awk '
        BEGIN { stop = "" }
        {
            if (stop != "") {
                t = $0; sub(/^[[:blank:]]+/, "", t)
                if (t == stop) stop = ""
                print ""
                next
            }
            print
            if (match($0, /<<-?[[:blank:]]*/)) {
                rest = substr($0, RSTART + RLENGTH)
                # Quoted delimiters (<<'"'"'EOF'"'"', <<"EOF") are the common form,
                # so peel the quotes off before reading the word. A quoted
                # delimiter whose closing quote is missing is not a plain
                # heredoc opener; treat it as none and keep scanning.
                q = substr(rest, 1, 1)
                if (q == "\047" || q == "\"") {
                    rest = substr(rest, 2)
                    if (length(rest) == 0 || substr(rest, length(rest), 1) != q) rest = ""
                    else rest = substr(rest, 1, length(rest) - 1)
                }
                # The delimiter must run to end of line, so arithmetic shifts
                # ($((a << b))) and here-strings (<<<) are not mistaken for one.
                if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*[[:blank:]]*$/)) {
                    stop = rest; sub(/[[:blank:]]+$/, "", stop)
                }
            }
        }
    ' "$1"
}
for f in "$INSTALL" "$ENTWARE"; do
    name="$(basename -- "$f")"
    hits="$(bash_code_only "$f" | grep -nE '^[[:space:]]*print -|\$\{\(|\$\+\(|(^|[[:space:]])setopt([[:space:]]|$)' || true)"
    if [ -z "$hits" ]; then
        ok "$name contains no zsh-only builtin or expansion"
    else
        no "$name contains no zsh-only builtin or expansion" "$(printf '%s' "$hits" | head -3)"
    fi
    # A filter that swallowed the rest of the file would also report no hits, so
    # require it to have blanked bodies rather than deleted them. If this fails,
    # some heredoc in the file has a form the scanner does not close (a delimiter
    # followed by a redirect, say) — and every check above is then blind.
    check "$name: blanking preserves line count, so no code hid in an unclosed body" \
        "$(wc -l < "$f" | tr -d ' ')" "$(bash_code_only "$f" | wc -l | tr -d ' ')"
done

# Both halves of the check above have to be able to fail, or it proves nothing:
# the exact line the installers used to carry must be a hit, and the same line
# must be invisible once it sits in a heredoc body.
if printf '    print -r -- "# generated"\n' | grep -qE '^[[:space:]]*print -'; then
    ok "the zsh-ism pattern matches the line it exists for"
else
    no "the zsh-ism pattern matches the line it exists for"
fi
probe="$TMP/heredoc-probe.sh"
printf '%s\n' "cat <<'TPL'" 'setopt appendhistory sharehistory' 'TPL' 'print -r -- "outside"' > "$probe"
if [ "$(bash_code_only "$probe" | grep -cE '(^|[[:space:]])setopt([[:space:]]|$)')" = "0" ] \
   && bash_code_only "$probe" | grep -qE '^[[:space:]]*print -'; then
    ok "the heredoc filter hides template zsh and keeps executed zsh"
else
    no "the heredoc filter hides template zsh and keeps executed zsh" "$(bash_code_only "$probe")"
fi

echo ""
echo ""
echo "=== 8. install, then uninstall, gives the config back ==="
# Everything above asks "did the installer write what it should?". This asks the
# other half of the promise, and the one nobody can eyeball from the source:
# does removing it again leave the USER's lines alone? The .zshrc is the single
# file here that cannot be re-downloaded, so "the uninstaller deleted something
# it never wrote" is the worst bug these scripts can have -- which is why the
# config is seeded with content the installer never touched, and the round trip
# is compared byte for byte against that seed.
UL=roundtrip
printf 'export USER_ONLY=1\nalias ll="ls -l"\n' > "$TMP/$UL.seed"
run_installer "$UL" NONINTERACTIVE=1 SKIP_DEPS=1 SMART_INSTALL_LANG=en
assert_run "$UL" 0
assert_installed "$UL"
u_home="$TMP/h_$UL"

# Witness before anything is claimed: had the install not really modified the
# seeded config, the byte-for-byte comparison further down would pass on a run
# that never had anything to remove.
if cmp -s "$u_home/.zshrc" "$TMP/$UL.seed"; then
    no "$UL: the install actually changed the seeded config" \
       "seed and installed config are identical, so everything below is vacuous"
else
    ok "$UL: the install actually changed the seeded config"
fi

# The uninstall run: same home, same stub PATH, the env knob rather than a flag
# (argv does not survive `curl | bash`, so this is the form that works there).
run_uninstall() {   # run_uninstall <label> <home> <NAME=value>...
    label="$1"; home="$2"; shift 2
    : > "$STUB_LOG"
    env -i PATH="$BIN:$CORE" \
        HOME="$home" ZDOTDIR="$home" \
        XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
        TERM="${TERM:-dumb}" TMPDIR="${TMPDIR:-/tmp}" \
        SMART_UNINSTALL=1 "$@" \
        bash "$INSTALL" > "$TMP/$label.out" 2>&1
    printf '%s' "$?" > "$TMP/$label.rc"
    cp "$STUB_LOG" "$TMP/$label.stubs.log"
}
U2="${UL}_uninstall"
run_uninstall "$U2" "$u_home" NONINTERACTIVE=1 SMART_INSTALL_LANG=en
assert_run "$U2" 0

if cmp -s "$u_home/.zshrc" "$TMP/$UL.seed"; then
    ok "$UL: the config is byte for byte what it was before the install"
else
    no "$UL: the config is byte for byte what it was before the install" \
       "got: $(tr '\n' '|' < "$u_home/.zshrc")"
fi
for gone in \
    "$u_home/.local/share/zinit/plugins/imonior---zsh-smart-complete" \
    "$u_home/.config/zsh-smart-complete" \
    "$u_home/.local/bin/zsc-settings"; do
    if [ -e "$gone" ]; then
        no "$UL: $gone was removed"
    else
        ok "$UL: $gone was removed"
    fi
done
# Uninstalling must not uninstall the world: zinit, starship, atuin and fzf are
# shared with the rest of the shell and may have been there before we ran.
if grep -qiE "uninstall|remove|purge|clean" "$TMP/$U2.stubs.log"; then
    no "$UL: it left the shared packages alone" \
       "$(grep -iE 'uninstall|remove|purge|clean' "$TMP/$U2.stubs.log" | head -1)"
else
    ok "$UL: it left the shared packages alone"
fi
# The safety net: the pre-edit copy still holds what was taken out. The NEWEST
# one is the copy the uninstall took moments before stripping it; `head -1` over
# an unordered `find` handed back whichever came first, which is the install's own
# backup of the seeded config — a file with nothing managed in it, so this failed
# whenever the two runs did not collide in the same second.
bak="$(find "$u_home" -maxdepth 1 -name '.zshrc.bak.*' 2>/dev/null | sort | tail -1)"
if [ -n "$bak" ] && grep -q ">>> zsh-smart-complete" "$bak"; then
    ok "$UL: a backup was taken before the edit, and it still holds the managed blocks"
else
    no "$UL: a backup was taken before the edit, and it still holds the managed blocks" "bak=[$bak]"
fi
if grep -q "Restart zsh" "$TMP/$U2.out"; then
    ok "$UL: and it tells the user the change needs a new shell"
else
    no "$UL: and it tells the user the change needs a new shell" "$(tail -3 "$TMP/$U2.out")"
fi

# Again, with nothing left of ours: it must say so rather than report a cleanup.
#
# Against the set as the previous run left it, not against a fixed number: both
# the install and the uninstall back the config up, and both name the copy
# `.zshrc.bak.<epoch>` — in the second where the two runs agree the newer one
# silently overwrites the older, so "1 file" was never the invariant, it was a
# coin flip that happened to land on its head most of the time.
baks_before="$(find "$u_home" -maxdepth 1 -name '.zshrc.bak.*' 2>/dev/null | wc -l | tr -d ' ')"
U3="${UL}_again"
run_uninstall "$U3" "$u_home" NONINTERACTIVE=1 SMART_INSTALL_LANG=en
assert_run "$U3" 0
if grep -q "Nothing to uninstall" "$TMP/$U3.out"; then
    ok "$UL: a second run says there is nothing to uninstall"
else
    no "$UL: a second run says there is nothing to uninstall" "$(tail -3 "$TMP/$U3.out")"
fi
baks_now="$(find "$u_home" -maxdepth 1 -name '.zshrc.bak.*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$baks_now" = "$baks_before" ] && cmp -s "$u_home/.zshrc" "$TMP/$UL.seed"; then
    ok "$UL: and the no-op run did not stack a second backup or edit the config"
else
    no "$UL: and the no-op run did not stack a second backup or edit the config" \
       "backups $baks_before -> $baks_now: $(find "$u_home" -maxdepth 1 -name '.zshrc.bak.*' 2>/dev/null | sort | tr '\n' ' ')"
fi

echo "INSTALLER-SANDBOX TOTAL PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
