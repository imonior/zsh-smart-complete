#!/usr/bin/env zsh
# tests/test-atuin.zsh
#
# v0.2.0 Atuin SQLite backend tests.
#
# Scenarios:
#   1. env not ready (no sqlite3 or no db file) → backend returns 1, history
#      core falls back to zsh
#   2. Happy path with mocked sqlite DB → correct command ordering,
#      metadata assocs populated (cwd/host/exit)
#   3. Same-host boost: identical command pair differing only in hostname →
#      local host wins
#   4. Exit penalty: failed command (exit=1) vs success (exit=0) → success wins
#   5. CWD + host combined → combined multipliers stack
#   6. SMART_ATUIN_SUCCESS_ONLY=true → exit != 0 rows filtered
#
# If sqlite3 is not available on PATH, scenarios 2-6 are SKIP'd (exit 0).

emulate -L zsh
setopt extended_glob no_warn_create_global
ROOT="${0:a:h:h}"
PASS=0
FAIL=0
SKIP=0

assert_eq() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        (( PASS++ )); print -r -- "  PASS  $name"
    else
        (( FAIL++ )); print -r -- "  FAIL  $name  got=[$got] want=[$want]" >&2
    fi
}
assert_ge() {
    local name="$1" got="$2" min="$3"
    if (( got >= min )); then
        (( PASS++ )); print -r -- "  PASS  $name  (got=$got ≥ $min)"
    else
        (( FAIL++ )); print -r -- "  FAIL  $name  got=[$got] want≥$min" >&2
    fi
}

source "${ROOT}/lib/config.zsh"
source "${ROOT}/lib/state.zsh"
source "${ROOT}/lib/engine/ranking.zsh"
source "${ROOT}/lib/history/history.zsh"
source "${ROOT}/lib/history/zsh.zsh"
source "${ROOT}/lib/history/atuin.zsh"
source "${ROOT}/lib/engine/suggest.zsh"

HAS_SQLITE=0
command -v sqlite3 >/dev/null 2>&1 && HAS_SQLITE=1

# ---------------------------------------------------------------------------
print -r -- "=== 场景 1: 环境未就绪时优雅降级 ==="
# Run against a non-existent DB path → backend returns 1
TMPDB="$(mktemp -u)"  # doesn't exist
saved_path="$SMART_ATUIN_DB_PATH"
SMART_ATUIN_DB_PATH="$TMPDB"

typeset -ga _SMART_BUILD_ORDER=()
typeset -gA _SMART_BUILD_FREQ=()
typeset -gA _SMART_BUILD_SEEN=()
typeset -gA _SMART_BUILD_REC_RANKS=()
typeset -gi _SMART_BUILD_MAX_F=0
typeset -gi _SMART_BUILD_REC=0
typeset -gA _SMART_BUILD_META_CWD=()
typeset -gA _SMART_BUILD_META_HOST=()
typeset -gA _SMART_BUILD_META_EXIT=()
typeset -gA _SMART_BUILD_META_SEEN_META=()

_smart_history_backend_atuin_build 100
rc=$?
unset _SMART_BUILD_ORDER _SMART_BUILD_FREQ _SMART_BUILD_SEEN \
      _SMART_BUILD_REC_RANKS _SMART_BUILD_MAX_F _SMART_BUILD_REC \
      _SMART_BUILD_META_CWD _SMART_BUILD_META_HOST \
      _SMART_BUILD_META_EXIT _SMART_BUILD_META_SEEN_META 2>/dev/null

if (( rc != 0 )); then
    (( PASS++ )); print -r -- "  PASS  missing DB → rc != 0 (graceful fallback)"
else
    (( FAIL++ )); print -r -- "  FAIL  missing DB expected rc≠0 got rc=$rc" >&2
fi
SMART_ATUIN_DB_PATH="$saved_path"

# ---------------------------------------------------------------------------
print -r -- ""
if (( HAS_SQLITE == 0 )); then
    print -r -- "=== 场景 2-6 跳过 (sqlite3 不在 PATH) ==="
    (( SKIP+=5 ))
else
print -r -- "=== 场景 2: Mock Atuin DB → build 正确填缓存 ==="
TEST_DB="$(mktemp)"
SMART_ATUIN_DB_PATH="$TEST_DB"

# Schema mirroring Atuin's core columns (v0.45.x – v0.50.x compatible set).
sqlite3 "$TEST_DB" <<'SQL' 2>/dev/null
CREATE TABLE history (
  id       TEXT PRIMARY KEY,
  command  TEXT,
  cwd      TEXT,
  exit     INTEGER,
  hostname TEXT,
  timestamp INTEGER
);
-- Order by timestamp descending. Most recent = highest timestamp.
INSERT INTO history VALUES ('a1', 'docker ps',                '/tmp',        0, 'other-server', 1000);
INSERT INTO history VALUES ('a2', 'docker compose up -d',    '/srv/docker',  0, 'other-server', 2000);
INSERT INTO history VALUES ('a3', 'docker ps',                '/tmp',        0, 'my-laptop',    3000);
INSERT INTO history VALUES ('a4', 'git status',               '/repo',       1, 'my-laptop',    4000);
INSERT INTO history VALUES ('a5', 'git status',               '/repo',       0, 'my-laptop',    5000);
INSERT INTO history VALUES ('a6', 'npm test',                 '/frontend',   0, 'workstation',  6000);
INSERT INTO history VALUES ('a7', 'npm test',                 '/frontend',   0, 'my-laptop',    7000);
SQL

# Setup scratch arrays & build.
typeset -ga _SMART_BUILD_ORDER=()
typeset -gA _SMART_BUILD_FREQ=()
typeset -gA _SMART_BUILD_SEEN=()
typeset -gA _SMART_BUILD_REC_RANKS=()
typeset -gi _SMART_BUILD_MAX_F=0
typeset -gi _SMART_BUILD_REC=0
typeset -gA _SMART_BUILD_META_CWD=()
typeset -gA _SMART_BUILD_META_HOST=()
typeset -gA _SMART_BUILD_META_EXIT=()
typeset -gA _SMART_BUILD_META_SEEN_META=()

_smart_history_backend_atuin_build 100
rc=$?

if (( rc == 0 )); then
    (( PASS++ )); print -r -- "  PASS  atuin_build returned rc=0"
else
    (( FAIL++ )); print -r -- "  FAIL  atuin_build rc=$rc expected 0" >&2
fi

# Distinct cmds from 7 rows: docker ps, docker compose up -d, git status, npm test → 4
assert_eq "distinct cmd count" "${#_SMART_BUILD_ORDER[@]}" "4"
# Newest → oldest after dedup. Rec = order index (0..3).
assert_eq "order[0] newest" "${_SMART_BUILD_ORDER[1]}" "npm test"
assert_eq "order[1]"        "${_SMART_BUILD_ORDER[2]}" "git status"
assert_eq "order[2]"        "${_SMART_BUILD_ORDER[3]}" "docker ps"
assert_eq "order[3] oldest" "${_SMART_BUILD_ORDER[4]}" "docker compose up -d"

# Frequency counts (dedup across all 7 rows).
assert_eq "freq docker ps"             "${_SMART_BUILD_FREQ[docker ps]}" "2"
assert_eq "freq docker compose up -d"  "${_SMART_BUILD_FREQ[docker compose up -d]}" "1"
assert_eq "freq git status"            "${_SMART_BUILD_FREQ[git status]}" "2"
assert_eq "freq npm test"              "${_SMART_BUILD_FREQ[npm test]}" "2"

# max_freq across all = 2
assert_eq "max_freq" "$_SMART_BUILD_MAX_F" "2"
# max_rec = 3 (4 distinct cmds, indexed 0..3)
assert_eq "max_rec"  "$_SMART_BUILD_REC" "3"

# Metadata (MOST RECENT row wins → stored when timestamp DESC FIRST hits cmd).
assert_eq "meta npm test cwd"       "${_SMART_BUILD_META_CWD[npm test]}"       "/frontend"
assert_eq "meta npm test host"      "${_SMART_BUILD_META_HOST[npm test]}"      "my-laptop"
assert_eq "meta npm test exit"      "${_SMART_BUILD_META_EXIT[npm test]}"      "0"
# git status: newest (ts=5000) has exit=0, cwd=/repo, host=my-laptop
assert_eq "meta git status host"    "${_SMART_BUILD_META_HOST[git status]}"    "my-laptop"
assert_eq "meta git status exit"    "${_SMART_BUILD_META_EXIT[git status]}"    "0"
# docker ps newest ts=3000, host=my-laptop
assert_eq "meta docker ps host"     "${_SMART_BUILD_META_HOST[docker ps]}"     "my-laptop"
assert_eq "meta docker ps exit"     "${_SMART_BUILD_META_EXIT[docker ps]}"     "0"

unset _SMART_BUILD_ORDER _SMART_BUILD_FREQ _SMART_BUILD_SEEN \
      _SMART_BUILD_REC_RANKS _SMART_BUILD_MAX_F _SMART_BUILD_REC \
      _SMART_BUILD_META_CWD _SMART_BUILD_META_HOST \
      _SMART_BUILD_META_EXIT _SMART_BUILD_META_SEEN_META 2>/dev/null
rm -f "$TEST_DB"
SMART_ATUIN_DB_PATH="$saved_path"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 3: Same-host boost ==="
# Two "docker ps" candidates with same freq/rec/cwd — different host.
# current_host = my-laptop → HOST_BOOST = 1300 gives +30% over other-server.
local s_local s_remote
s_local=$(_smart_score_total "docker " "docker ps" 2 1 2 3 \
            "/tmp" "/other" \
            "my-laptop" "my-laptop" "0")
s_remote=$(_smart_score_total "docker " "docker ps" 2 1 2 3 \
            "/tmp" "/other" \
            "other-server" "my-laptop" "0")
assert_ge "host boost: local > remote" "$s_local" "$(( s_remote + 1 ))"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 4: Exit penalty ==="
# Two "git status" with all else equal — but exit status differs.
# Avoid CWD/Host boost from clamping the pre-penalty score at 1000 by
# leaving those params empty here.
local s_ok s_bad
s_ok=$(_smart_score_total  "git " "git status" 2 1 2 3 \
            "" "" "" "" "0")
s_bad=$(_smart_score_total "git " "git status" 2 1 2 3 \
            "" "" "" "" "1")
# s_bad = s_ok * 0.5 → s_ok strictly greater
assert_ge "exit penalty: success > failed" "$s_ok" "$(( s_bad + 1 ))"
# Ratio ~2x, accept 1.8x (18 in tenths).
(( s_bad > 0 )) && {
    local ratio=$(( s_ok * 10 / s_bad ))
    assert_ge "exit penalty ratio ≈ 2.0x" "$ratio" "18"
}

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 5: CWD + host stacked multipliers ==="
# local match + same cwd → 1.5 * 1.3 = 1.95x base vs. remote + diff-cwd.
local s_stacked s_baseline
s_stacked=$(_smart_score_total  "npm " "npm test" 1 0 2 3 \
                "/frontend" "/frontend" "my-laptop" "my-laptop" "0")
s_baseline=$(_smart_score_total "npm " "npm test" 1 0 2 3 \
                "/backend"  "/frontend" "other-server" "my-laptop" "0")
assert_ge "stacked(cwd+host) > baseline" "$s_stacked" "$(( s_baseline + 1 ))"

# ---------------------------------------------------------------------------
print -r -- ""
print -r -- "=== 场景 6: SMART_ATUIN_SUCCESS_ONLY=true 过滤失败命令 ==="
TEST_DB2="$(mktemp)"
SMART_ATUIN_DB_PATH="$TEST_DB2"
sqlite3 "$TEST_DB2" <<'SQL' 2>/dev/null
CREATE TABLE history (id TEXT, command TEXT, cwd TEXT, exit INTEGER, hostname TEXT, timestamp INTEGER);
INSERT INTO history VALUES ('1','badcmd rm -rf /','/',1,'my-laptop',100);
INSERT INTO history VALUES ('2','goodcmd echo hi','/',0,'my-laptop',200);
SQL

SMART_ATUIN_SUCCESS_ONLY=true
typeset -ga _SMART_BUILD_ORDER=()
typeset -gA _SMART_BUILD_FREQ=()
typeset -gA _SMART_BUILD_SEEN=()
typeset -gA _SMART_BUILD_REC_RANKS=()
typeset -gi _SMART_BUILD_MAX_F=0
typeset -gi _SMART_BUILD_REC=0
typeset -gA _SMART_BUILD_META_CWD=()
typeset -gA _SMART_BUILD_META_HOST=()
typeset -gA _SMART_BUILD_META_EXIT=()
typeset -gA _SMART_BUILD_META_SEEN_META=()

_smart_history_backend_atuin_build 100
assert_eq "success_only distinct count" "${#_SMART_BUILD_ORDER[@]}" "1"
assert_eq "success_only cmd"             "${_SMART_BUILD_ORDER[1]}" "goodcmd echo hi"

unset _SMART_BUILD_ORDER _SMART_BUILD_FREQ _SMART_BUILD_SEEN \
      _SMART_BUILD_REC_RANKS _SMART_BUILD_MAX_F _SMART_BUILD_REC \
      _SMART_BUILD_META_CWD _SMART_BUILD_META_HOST \
      _SMART_BUILD_META_EXIT _SMART_BUILD_META_SEEN_META 2>/dev/null
SMART_ATUIN_SUCCESS_ONLY=false
rm -f "$TEST_DB2"
SMART_ATUIN_DB_PATH="$saved_path"
fi  # HAS_SQLITE

# ---------------------------------------------------------------------------
print -r -- ""
if (( SKIP > 0 )); then
    print -r -- "=== TOTAL: $PASS passed, $FAIL failed, $SKIP skipped ==="
else
    print -r -- "=== TOTAL: $PASS passed, $FAIL failed ==="
fi
(( FAIL == 0 )) && exit 0 || exit 1
