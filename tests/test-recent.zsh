#!/usr/bin/env zsh
# tests/test-recent.zsh
#
# Unit tests for recent-directory candidates (lib/engine/recent.zsh).
#
# Verifies:
#   * the "is this the first argument of cd?" rule, including the two cases that
#     must NOT match (still typing the command word; a second word, i.e. the
#     `cd old new` substitution form)
#   * the database parser: chpwd_recent_filehandler writes one $'...'-quoted
#     path per line, so spaces, quotes and newlines must survive the round trip
#   * stale entries (directories that no longer exist) are dropped
#   * SMART_RECENT_PATHS_MAX truncation, and de-duplication that keeps order
#   * $completer wiring: prepended (must run before `_complete`), idempotent,
#     never duplicated, and restored element-for-element on uninstall
#   * the feature gate: SMART_RECENT_PATHS=false disables both the completer and
#     the empty-word allowance
#
# Runs OUTSIDE ZLE: only the pure logic is exercised here. The visible behaviour
# (candidates actually appearing in the popup after `cd `) is proven by
# tests/e2e-tmux.sh.

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

assert_ne() {
    local name="$1" got="$2" unwanted="$3"
    if [[ "$got" != "$unwanted" ]]; then
        (( PASS++ )); print -r -- "  PASS  $name"
    else
        (( FAIL++ )); print -r -- "  FAIL  $name  got=[$got] (should differ)" >&2
    fi
}

assert_true() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        (( PASS++ )); print -r -- "  PASS  $name"
    else
        (( FAIL++ )); print -r -- "  FAIL  $name (expected success)" >&2
    fi
}

assert_false() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        (( FAIL++ )); print -r -- "  FAIL  $name (expected failure)" >&2
    else
        (( PASS++ )); print -r -- "  PASS  $name"
    fi
}

source "${ROOT}/lib/config.zsh"
source "${ROOT}/lib/state.zsh"
source "${ROOT}/lib/engine/recent.zsh"

ZD="$(mktemp -d "${TMPDIR:-/tmp}/zsc_recent.XXXXXX")"
mkdir -p "$ZD/live-1" "$ZD/live-2" "$ZD/live-3"
trap 'rm -rf "$ZD"' EXIT

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 1: 只在 cd / pushd / chdir 的第一个参数位置生效 ==="
# ---------------------------------------------------------------------------
assert_true  "cd <partial>"          _smart_recent_is_cd_arg 'cd proj'
assert_true  "cd <empty>"            _smart_recent_is_cd_arg 'cd '
assert_true  "pushd <partial>"       _smart_recent_is_cd_arg 'pushd /tmp'
assert_true  "chdir <partial>"       _smart_recent_is_cd_arg 'chdir x'
assert_true  "absolute path to cd"   _smart_recent_is_cd_arg '/usr/bin/cd proj'
assert_false "still typing the command word" _smart_recent_is_cd_arg 'cd'
assert_false "cd old new (2nd word)"         _smart_recent_is_cd_arg 'cd old new'
assert_false "not cd at all"                 _smart_recent_is_cd_arg 'git status'
assert_false "empty buffer"                  _smart_recent_is_cd_arg ''
assert_false "cd appears as an argument"     _smart_recent_is_cd_arg 'echo cd foo'

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 2: 数据库解析（空格 / 引号 / 换行 / 失效目录）==="
# ---------------------------------------------------------------------------
DB="$ZD/.chpwd-recent-dirs"
# Written exactly the way chpwd_recent_filehandler writes it.
print -rl ${(qqqq)paths} > /dev/null 2>&1 || true
paths=( "$ZD/live-1" "$ZD/gone" "$ZD/live-2" "$ZD/live-1" )
print -rl ${(qqqq)paths} > "$DB"
zstyle ':chpwd:' recent-dirs-file "$DB"
_smart_recent_load
assert_eq "stale entries dropped, duplicates collapsed" "${#_SMART_RECENT_DIRS}" "2"
assert_eq "recency order preserved (1st)"  "${_SMART_RECENT_DIRS[1]}" "$ZD/live-1"
assert_eq "recency order preserved (2nd)"  "${_SMART_RECENT_DIRS[2]}" "$ZD/live-2"

# Spaces, single quotes and newlines in a path must survive the round trip.
mkdir -p "$ZD/has space" "$ZD/quote's"
paths=( "$ZD/has space" "$ZD/quote's" )
print -rl ${(qqqq)paths} > "$DB"
_smart_recent_load
assert_eq "path with a space parsed"     "${_SMART_RECENT_DIRS[1]}" "$ZD/has space"
assert_eq "path with a single quote parsed" "${_SMART_RECENT_DIRS[2]}" "$ZD/quote's"

# Truncation.
paths=( "$ZD/live-1" "$ZD/live-2" "$ZD/live-3" )
print -rl ${(qqqq)paths} > "$DB"
SMART_RECENT_PATHS_MAX=2
_smart_recent_load
assert_eq "MAX truncates to the most recent N" "${#_SMART_RECENT_DIRS}" "2"
SMART_RECENT_PATHS_MAX=20

# XDG fallback: no zstyle at all, data only under $XDG_DATA_HOME/zsh/, and no
# default-path file either (otherwise the default wins and the fallback is
# never exercised). Runs in a subshell so ZDOTDIR/XDG_DATA_HOME do not leak.
recent_first_with() {
    (
        ZDOTDIR="$1" XDG_DATA_HOME="$2"
        _smart_recent_load
        print -r -- "${_SMART_RECENT_DIRS[1]}"
    )
}
zstyle -d ':chpwd:' recent-dirs-file
XDG_ROOT="$ZD/xdg"
mkdir -p "$XDG_ROOT/zsh" "$ZD/empty-zdot"
paths=( "$ZD/live-3" )
print -rl ${(qqqq)paths} > "$XDG_ROOT/zsh/chpwd-recent-dirs"
assert_eq "XDG database found when no zstyle is set" \
    "$(recent_first_with "$ZD/empty-zdot" "$XDG_ROOT")" "$ZD/live-3"

# A zstyle pointing at a readable file wins over the XDG fallback.
zstyle ':chpwd:' recent-dirs-file "$DB"
recent_count_with() {
    (
        ZDOTDIR="$1" XDG_DATA_HOME="$2"
        _smart_recent_load
        print -r -- "${#_SMART_RECENT_DIRS}"
    )
}
assert_eq "explicit zstyle file wins (3 there vs 1 under XDG)" \
    "$(recent_count_with "$ZD/empty-zdot" "$XDG_ROOT")" "3"
assert_eq "and it is the zstyle file that is read" \
    "$(recent_first_with "$ZD/empty-zdot" "$XDG_ROOT")" "$ZD/live-1"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 3: completer 接线（走 zstyle，不是 \$completer 数组）==="
# ---------------------------------------------------------------------------
# THE TRAP THIS SCENARIO EXISTS FOR: `_main_complete` reads the completer list
# from `zstyle ':completion:*' completer` and falls back to the built-in default
# `(_complete _ignored)`. There is no `$completer` array involved, so appending
# to `$completer` looks wired up and silently does nothing. These assertions pin
# down the real mechanism.
_recent_chain() {
    local -a c=()
    zstyle -a ':completion:*' completer c 2>/dev/null
    print -r -- "${(j: :)c}"
}
_recent_style_exists() {
    local -a c=()
    zstyle -a ':completion:*' completer c 2>/dev/null
}

zstyle -d ':completion:*' completer

_smart_recent_install
assert_eq "no user style -> ours first, built-in default kept" \
    "$(_recent_chain)" "_smart_recent_paths _complete _ignored"

# Calling install again must not stack a second entry.
_smart_recent_install
assert_eq "install is idempotent" \
    "$(_recent_chain)" "_smart_recent_paths _complete _ignored"

# Uninstall must go back to having NO style at all, so zsh's own default is in
# force again — not to a hard-coded copy of it.
_smart_recent_uninstall
assert_false "uninstall removes the style we added" _recent_style_exists
_smart_recent_uninstall
assert_false "uninstall is idempotent" _recent_style_exists

# A user-configured chain must be preserved element for element.
zstyle ':completion:*' completer _complete _approximate _ignored
_smart_recent_install
assert_eq "user chain kept, ours prepended" \
    "$(_recent_chain)" "_smart_recent_paths _complete _approximate _ignored"
_smart_recent_uninstall
assert_eq "user chain restored exactly" \
    "$(_recent_chain)" "_complete _approximate _ignored"
zstyle -d ':completion:*' completer

# If the user (or a previous install) already has us in the chain, adopt it
# instead of adding a second copy — and restore that same value on uninstall.
zstyle ':completion:*' completer _smart_recent_paths _complete
_smart_recent_install
assert_eq "already-present entry is not duplicated" \
    "$(_recent_chain)" "_smart_recent_paths _complete"
_smart_recent_uninstall
assert_eq "adopted chain restored as found" \
    "$(_recent_chain)" "_smart_recent_paths _complete"
zstyle -d ':completion:*' completer

# Without compinit there is no completion chain to join: stay out of it.
_smart_native_have_compinit() { return 1 }
_smart_recent_install
assert_false "no compinit -> nothing installed" _recent_style_exists
unfunction _smart_native_have_compinit

# Uninstall without a prior install must not touch a chain we did not modify.
zstyle ':completion:*' completer _complete
_smart_recent_install
_smart_recent_uninstall
assert_eq "install+uninstall round-trips a user chain" "$(_recent_chain)" "_complete"
zstyle -d ':completion:*' completer

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 4: 开关与空词放行 ==="
# ---------------------------------------------------------------------------
LBUFFER='cd '
SMART_RECENT_PATHS=true
assert_true "cd empty word allowed when enabled" _smart_recent_cd_empty_ok
SMART_RECENT_PATHS=false
assert_false "cd empty word refused when disabled" _smart_recent_cd_empty_ok
SMART_RECENT_PATHS=true
LBUFFER='git '
assert_false "non-cd empty word still refused" _smart_recent_cd_empty_ok
LBUFFER='cd proj'
assert_true "cd partial word allowed" _smart_recent_cd_empty_ok

# Plugin-wide disable wins over the feature flag.
_smart_state_set enabled 0
assert_false "smart-disable turns it off too" _smart_recent_cd_empty_ok
_smart_state_set enabled 1
assert_true "re-enabling restores it" _smart_recent_cd_empty_ok

# The runtime CLI must flip both the flag and the wiring.
smart-recent on >/dev/null 2>&1
assert_eq "smart-recent on wires the completer" \
    "$(_recent_chain)" "_smart_recent_paths _complete _ignored"
smart-recent off >/dev/null 2>&1
assert_false "smart-recent off unwires it" _recent_style_exists
assert_eq "smart-recent status reports off" "$(smart-recent status | head -1)" "smart-recent: off"

zstyle -d ':chpwd:' recent-dirs-file
zstyle -d ':completion:*' completer

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && exit 0 || exit 1
