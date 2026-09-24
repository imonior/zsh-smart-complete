#!/usr/bin/env zsh
# tests/test-state.zsh
#
# Unit tests for the state container (lib/state.zsh): the accessor helpers and
# the fast history-index mirrors (_SMART_CMDS / _SMART_CMDS_FIRST) that
# _smart_state_l_set maintains.
#
# Why this file exists: history.zsh and menu.zsh are tested through their own
# suites, but state.zsh itself — the module every one of them writes through —
# had no direct tests. The bucket mirror in particular went through a rewrite
# (incremental string append -> tag/sort/join, so that a 20k rebuild stops
# being quadratic), and a rewrite that keeps the SAME observable layout
# deserves the SAME proof: bucket membership, within-bucket order, and the
# newline round-trip through _smart_state_l_get.

emulate -L zsh
setopt extended_glob no_warn_create_global
ROOT="${0:a:h:h}"
PASS=0
FAIL=0

assert_eq() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        (( PASS++ )); print -r -- "  PASS  $name"
    else
        (( FAIL++ )); print -r -- "  FAIL  $name  got=[$got] want=[$want]" >&2
    fi
}
assert_rc() {
    local name="$1" want="$2"; shift 2
    "$@"; local rc=$?
    if (( rc == want )); then
        (( PASS++ )); print -r -- "  PASS  $name"
    else
        (( FAIL++ )); print -r -- "  FAIL  $name  rc=$rc want=$want" >&2
    fi
}

source "${ROOT}/lib/config.zsh"
source "${ROOT}/lib/state.zsh"

print -r -- "=== 场景 1: scalar accessors ==="
_smart_state_reset
assert_eq "enabled defaults to 1"     "${_SMART_STATE[enabled]}" "1"
# A slot whose stored value is "" is indistinguishable from a missing one for
# the reader, so the default kicks in — both cases are covered here on purpose.
assert_eq "get: default on an empty slot" "$(_smart_state_get buffer fallback)" "fallback"
_smart_state_set buffer "hello world"
assert_eq "get: stored value"         "$(_smart_state_get buffer fallback)" "hello world"
assert_eq "get: value with spaces"    "$(_smart_state_set buffer 'a b c'; _smart_state_get buffer)" "a b c"
assert_eq "get: zero is a real value, not the default" "$(_smart_state_get history.count 42)" "0"
_smart_state_set cursor 7
assert_eq "get: default unused when set" "$(_smart_state_get cursor 42)" "7"
assert_rc "set: empty key rejected"   1 _smart_state_set "" v
_smart_state_unset cursor
assert_eq "unset removes the slot"    "$(_smart_state_get cursor d)" "d"

print -r -- ""
print -r -- "=== 场景 2: associative sub-maps ==="
_smart_state_a_set history.frequency "git commit -a" 3
assert_eq "a_get round-trip (spaces, dots in key)" \
    "$(_smart_state_a_get history.frequency "git commit -a")" "3"
assert_eq "a_get default"             "$(_smart_state_a_get history.frequency "nope" 1)" "1"
assert_rc "a_set: empty key rejected" 1 _smart_state_a_set history.frequency "" 5
_smart_state_a_set history.frequency "git push" 2
_smart_state_a_unset_sub history.frequency
assert_eq "unset_sub drops the whole submap" \
    "$(_smart_state_a_get history.frequency "git push" gone)" "gone"
# A submap is addressed by its "sub|" prefix, so neighbours must survive.
_smart_state_a_set history.host "h1" "boxA"
_smart_state_a_set history.frequency "ls" 9
_smart_state_a_unset_sub history.frequency
assert_eq "unset_sub: other submap survives" \
    "$(_smart_state_a_get history.host "h1")" "boxA"
assert_eq "unset_sub: sibling key gone" \
    "$(_smart_state_a_get history.frequency "ls" gone)" "gone"

print -r -- ""
print -r -- "=== 场景 3: list slots round-trip ==="
_smart_state_l_set cmds "ls -la" "git status" "docker compose up -d"
assert_eq "l_get line count"          "$(_smart_state_l_get cmds | wc -l | tr -d ' ')" "3"
assert_eq "l_get content"             "$(_smart_state_l_get cmds)" $'ls -la\ngit status\ndocker compose up -d'
_smart_state_l_set cmds only-one
assert_eq "l_get single element"      "$(_smart_state_l_get cmds)" "only-one"
_smart_state_l_set cmds
assert_eq "l_get empty list -> no output" "$(_smart_state_l_get cmds)" ""

print -r -- ""
print -r -- "=== 场景 4: history.cmds mirrors + first-char buckets ==="
# Order: newest first as given. Two 'g' commands and interleaving prove that
# buckets preserve the array's relative order, not first-seen grouping order.
_smart_state_l_set history.cmds \
    "git commit -a" "ls /tmp" "git status" "grep -rn x ." "gcc -O2" "" "zsh"
assert_eq "mirror array size (empties included)" "${#_SMART_CMDS[@]}" "7"
assert_eq "g-bucket content" "${_SMART_CMDS_FIRST[g]}" $'git commit -a\ngit status\ngrep -rn x .\ngcc -O2'
assert_eq "l-bucket content" "${_SMART_CMDS_FIRST[l]}" "ls /tmp"
assert_eq "z-bucket content" "${_SMART_CMDS_FIRST[z]}" "zsh"
# An empty command has no first character, so it must not create a bucket.
_empty_keys=0
for _k in "${(@k)_SMART_CMDS_FIRST}"; do [[ -z "$_k" ]] && ((_empty_keys++)); done
assert_eq "no bucket keyed by the empty string" "$_empty_keys" "0"
assert_eq "bucket count == distinct first chars" "${#_SMART_CMDS_FIRST[@]}" "3"
# digits and punctuation as first chars exercise the tag/sort scheme at the
# byte boundaries of the alphabet.
_smart_state_l_set history.cmds "1st" "2nd" "_u" "-n" "#hash" "é accent"
assert_eq "digit bucket"      "${_SMART_CMDS_FIRST[1]}" "1st"
assert_eq "dash bucket"       "${_SMART_CMDS_FIRST[-]}" "-n"
assert_eq "hash bucket"       "${_SMART_CMDS_FIRST[#]}" "#hash"
assert_eq "underscore bucket" "${_SMART_CMDS_FIRST[_]}" "_u"
# Multibyte first char. The invariant is NOT "the key is é" — under a C locale
# é is two bytes and ${cmd[1]} yields the lead byte — it is that the builder and
# every reader derive the key the same way, from ${x[1]} of the same string.
_mb_cmd="é accent"
_mb_key="${_mb_cmd[1]}"
assert_eq "multibyte command lands in its first-char bucket" \
    "${_SMART_CMDS_FIRST[$_mb_key]}" "$_mb_cmd"
# rebuild must be replace-not-append: stale keys go away
_smart_state_l_set history.cmds "alpha" "beta"
assert_eq "stale buckets dropped on replace" "${#_SMART_CMDS_FIRST[@]}" "2"
assert_eq "stale digit bucket is gone"  "${_SMART_CMDS_FIRST[1]-<unset>}" "<unset>"
assert_eq "stale g bucket is gone"      "${_SMART_CMDS_FIRST[g]-<unset>}" "<unset>"
# store round-trip through l_get must agree with the array
assert_eq "store matches array" "$(_smart_state_l_get history.cmds)" $'alpha\nbeta'

print -r -- ""
print -r -- "=== 场景 4b: glob-magic first chars must match literally ==="
# The buckets are built with a pattern filter (${(M@)_SMART_CMDS:#${k}*}), so a
# key that happens to be glob magic must not turn into a wildcard.
#
# The keys are read through variables on purpose, exactly like the library does
# (${prefix[1]}): a literal [*] subscript is zsh's "every value" form and a
# literal [[] or [\] does not even parse, so those spellings would test the
# subscript rules rather than the bucket contents.
_smart_state_l_set history.cmds "*rm -rf*" "?q" "[b" "<x" '$HOME' '\path' "#tag" "safe cmd"
typeset -A _want=( \
    '*' '*rm -rf*' \
    '?' '?q' \
    '[' '[b' \
    '<' '<x' \
    '$' '$HOME' \
    '\' '\path' \
    '#' '#tag' \
    's' 'safe cmd' \
)
for _mk in ${(k)_want}; do
    assert_eq "bucket [$_mk] holds exactly its own commands" \
        "${_SMART_CMDS_FIRST[$_mk]}" "${_want[$_mk]}"
done
assert_eq "one bucket per distinct first char" "${#_SMART_CMDS_FIRST[@]}" "8"

print -r -- ""
print -r -- "=== 场景 5: rebucket keeps positions intact across 10/100/1000 ==="
# The tag scheme pads positions to 8 digits and groups with a string sort;
# sizes crossing 9/99/999 are where an unpadded key would interleave buckets.
typeset -a many=()
for ((i=1; i<=1005; i++)); do many+=("k cmd$i"); done
many+=("j solo")
_smart_state_l_set history.cmds "${many[@]}"
_kk=("${(f)_SMART_CMDS_FIRST[k]}")
assert_eq "large bucket size"  "${#_kk[@]}" "1005"
assert_eq "large bucket first" "${_kk[1]}"  "k cmd1"
assert_eq "large bucket at 9->10 boundary"   "${_kk[10]}" "k cmd10"
assert_eq "large bucket at 99->100 boundary" "${_kk[100]}" "k cmd100"
assert_eq "large bucket last"  "${_kk[-1]}" "k cmd1005"
assert_eq "small bucket coexists" "${_SMART_CMDS_FIRST[j]}" "j solo"

print -r -- ""
print -r -- "=== 场景 6: reset ==="
_smart_state_reset
assert_eq "reset clears count"        "${_SMART_STATE[history.count]}" "0"
assert_eq "reset clears tick"         "${_SMART_STATE[history.tick]}" "0"
assert_eq "reset empties mirror"      "${#_SMART_CMDS[@]}" "0"
assert_eq "reset empties buckets"     "${#_SMART_CMDS_FIRST[@]}" "0"
assert_eq "reset re-arms enabled"     "${_SMART_STATE[enabled]}" "1"

print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
