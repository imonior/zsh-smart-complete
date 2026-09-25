# lib/engine/menu.zsh
#
# Type-to-popup completion menu — the zsh-autocomplete half of this plugin,
# implemented natively on top of the user's own compsys.
#
# WHAT IT DOES
#   Every time the buffer is edited we run a *listing* completion for the word
#   under the cursor. If the completion has >= SMART_MENU_MIN_MATCHES
#   candidates, the list is drawn below the line — while you type, without
#   pressing Tab. The list re-computes on every keystroke, so it shrinks and
#   grows with the prefix. When the prefix narrows to a single candidate the
#   list is dropped and the inline (grey) suggestion takes over.
#
# WHY IT DOES NOT CONFLICT WITH THE INLINE SUGGESTION
#   The completion list and the POSTDISPLAY ghost share the screen area below
#   the line, and any plain `zle -R` redraw wipes the list. So the order is
#   fixed: render the ghost FIRST (POSTDISPLAY + region_highlight), then run
#   the listing completion, whose own redraw paints line+ghost+list together.
#   Nothing redraws after that. See _smart_menu_tick.
#
# WHY IT DOES NOT TOUCH compinit
#   We never call compinit/compdef. We only borrow the completion *result* via
#   a private completion widget (`zle -C _smart_menu_list list-choices ...`)
#   whose function reads `compstate[nmatches]` and decides whether the list is
#   shown. If the user never ran compinit, the whole module is a no-op.
#
# KILL SWITCH
#   SMART_MENU=false          disable entirely (inline suggestion still works)
#   SMART_MENU_MIN_PREFIX=n   min chars before listing an ARGUMENT word (2)
#   SMART_MENU_MIN_PREFIX_CMD=n  min chars before listing the COMMAND word (2)
#   Both count the LAST SEGMENT of the word (`/etc/l` counts as one typed
#   character, not six) — see _smart_menu_word_tail.
#   SMART_MENU_MIN_MATCHES=n  don't list unless there are at least n (2)
#   SMART_MENU_MAX_MATCHES=n  don't list when there are more than n (100)
#   SMART_MENU_SINGLE_COLUMN=true  draw candidates one per line (vertical list)
#                                     instead of zsh's native multi-column grid.
#                                     OPT-IN (off by default): it is generated
#                                     rather than taken from compsys, so it
#                                     loses descriptions / colours / fuzzy
#                                     matching, and flips back to the grid for
#                                     contexts it cannot generate. See
#                                     lib/config.zsh for the full trade-off.
#   SMART_MENU_LISTER=fzf-tab  stop drawing OUR list; hand the screen to an
#                                     external floating picker (fzf-tab). Use it
#                                     when two lists appear at once. Inline
#                                     suggestion is unaffected.
#   SMART_MENU_HISTORY_KEYS=true  ↑/↓ prefix-search history (off by default)
#   SMART_RECENT_PATHS=false  drop recent directories + `cd ` empty-word listing
#   or, at runtime:  smart-menu off | on | status   /   smart-lister builtin|fzf-tab
#
# THROTTLE
#   OFF by default (SMART_MENU_COOLDOWN_KEYS=0), so the list always matches what
#   you typed. The mechanism exists for persistently expensive completions: a
#   listing at or above SMART_MENU_SLOW_MS (250) then buys a cool-down of
#   SMART_MENU_COOLDOWN_KEYS edits. Skipping an edit also drops the list that was
#   on screen, which is why it is off: the only spike we measured is a one-off
#   ~180ms when a completion subsystem loads, and throttling that just removes
#   the popup from the first command of the session.
#
# DEBUGGING
#   SMART_MENU_DEBUG=/tmp/zsc-menu.log logs every tick decision.
#
# This module knows about state + compsys. It does NOT know about history.

emulate -L zsh
setopt extended_glob no_warn_create_global

# Make completion lists scrollable instead of dumping every line. zsh/complist
# is what turns a long candidate list into a scrollable panel (one screenful at
# a time, paged with Space) instead of dumping every row at once.
#
# DO NOT scope-assign LISTMAX around the listing call. It looks like the obvious
# way to stop zsh asking "do you wish to see all N possibilities (M lines)?",
# but it corrupts ZLE's next input read and silently EATS ONE KEYSTROKE per
# listing: with it, typing `git status` leaves `gitstatus` in the buffer and the
# shell runs the wrong command. It was measured A/B across short and long lists
# (both directions broken) and is permanently gone. The prompt is prevented
# instead by SMART_MENU_MAX_MATCHES (see _smart_menu_decide_list), which simply
# declines to draw a list that big.
zmodload zsh/complist 2>/dev/null

# Defaults live in lib/config.zsh (the single source of truth).
# Result of the last listing run. Read by smart-menu status and the tests.
typeset -gi _SMART_MENU_NMATCHES=0
typeset -gi _SMART_MENU_LISTED=0
typeset -gi _SMART_MENU_TICKS=0
typeset -gi _SMART_MENU_SKIPS=0
typeset -gi _SMART_MENU_COOLDOWN=0
typeset -gi _SMART_MENU_LAST_MS=0
# 1 when the last listing was suppressed because it exceeded SMART_MENU_MAX_MATCHES.
typeset -gi _SMART_MENU_TRUNCATED=0
# 1 while candidate rows drawn by a PREVIOUS tick are still on the screen.
# Distinct from _SMART_MENU_LISTED, which only ever describes the CURRENT tick
# (it is reset to 0 before every listing). This one survives across ticks, which
# is what lets _smart_menu_forget_rows answer "is there anything below the line
# that I am responsible for?". See that function.
typeset -gi _SMART_MENU_ROWS=0

# Candidate buffer for the single-column (vertical) generator. Filled by
# _smart_menu_candidates, consumed by _smart_menu_list_main. Kept global so the
# generator can populate it without the local-scope pitfalls of `set -A name`.
typeset -ga _SMART_MENU_CAND=()
# Padded display strings, index-aligned with _SMART_MENU_CAND. Built by
# _smart_menu_single_display and handed straight to `compadd -d`.
typeset -ga _SMART_MENU_DISP=()

# Timing. zsh/datetime gives us sub-second wall clock; if the module is
# unavailable we simply never throttle (correct, just slower on hot paths).
# NOTE: EPOCHREALTIME is a PARAMETER, so the feature must be requested with
# the `p:` prefix. `b:EPOCHREALTIME` is rejected ("no such feature") and leaves
# the parameter undefined, which would silently disable all throttling.
zmodload -F zsh/datetime p:EPOCHREALTIME 2>/dev/null
_smart_menu_now_ms() {
    _smart_menu_now_ms_scan
    print -r -- "$_SMART_MENU_NOW_MS"
    return 0
}

# The scan form exists because the listing tick reads the clock twice per
# keystroke, and `_smart_menu_now_ms`'s print costs a subshell fork (~0.4 ms
# measured). Same digits, published through a global; the printing form stays
# for status output and tests. Return code says whether a clock exists at all,
# which is what _smart_menu_have_clock used to be asked on the tick path.
typeset -g _SMART_MENU_NOW_MS=0
_smart_menu_now_ms_scan() {
    local t="${EPOCHREALTIME:-}"
    if [[ -z "$t" ]]; then
        _SMART_MENU_NOW_MS=0
        return 1
    fi
    t="${t/./}"                      # 1789465211.123456 -> 1789465211123456
    _SMART_MENU_NOW_MS="${t[1,13]}"  # first 13 digits = milliseconds
    return 0
}
_smart_menu_have_clock() { [[ -n "${EPOCHREALTIME:-}" ]] }

# Optional decision trace. Set SMART_MENU_DEBUG=/path/to/log to append one line
# per tick (why it was skipped, what it cost, how many matched). This is the
# only way to answer "why is there no popup?" without guessing — the visible
# screen cannot distinguish "gate said no" from "cooldown ate it" from
# "completion found 1 match". Zero cost when unset (a single -n test).
_smart_menu_dbg() {
    [[ -n "${SMART_MENU_DEBUG:-}" ]] || return 0
    print -r -- "$*" >> "$SMART_MENU_DEBUG" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------

# _smart_menu_enabled -- 0 if the menu channel is allowed to run at all.
_smart_menu_enabled() {
    case "${SMART_MENU:-true}" in false|no|off|0|disabled) return 1 ;; esac
    (( ${_SMART_STATE[enabled]:-1} == 1 )) || return 1
    return 0
}

# _smart_menu_word -- the whitespace-delimited word under the cursor.
# Cheap (no regexp over the whole buffer, no compsys call). Per-keystroke
# callers inline the same expansion instead — even this one print costs a
# subshell fork per call (see _smart_menu_should_list).
_smart_menu_word() {
    print -r -- "${LBUFFER##*[[:space:]]}"
}

# _smart_menu_is_command_word -- is the word under the cursor in COMMAND
# position, i.e. does the shell still have to choose what to run there?
#
# The first word of the line is the obvious case, and the one this function
# used to cover completely. The others matter just as much when the live popup
# is in single-column mode, because that mode has to decide for itself:
#
#   * after a separator   — `git log | gr`, `make && gi`, `ls -la ; ch`
#   * after a wrapper     — `sudo gi`, `env FOO=1 vi`, `FOO=1 git`
#
# There, answering "second word, so it is a path" is wrong twice over: the
# filesystem glob has nothing to do with what the user is typing, and zsh's own
# completer does offer commands at those positions — so the generator, which
# used to fall through there, can now draw that list vertically too.
#
# The test is deliberately conservative about everything else: every word
# between the LAST separator and the cursor must be a wrapper or a `VAR=value`
# prefix assignment. `sudo git st` is therefore NOT a command position — `git`
# already owns that slot, `st` is a subcommand, and a subcommand is precisely
# what this generator cannot produce. A word it mis-splits out of a quoted
# argument is not on the list either, which is the same safe answer.
#
# COST, since this runs on the keystroke path. tests/test-perf.zsh section 5
# guards it; on the same 8 GB laptop it measures ~19 us per call for an ordinary
# two-word line (was ~4 us with the first-word-only test), less after a
# separator — the clip below leaves nothing to split — and ~80 us for a
# 350-character line with no separator at all, where the whole prefix has to be
# split to discover that its first word is not a wrapper. Every one of those is
# well under the ~400 us a single subshell fork costs in this codebase, which is
# the unit these numbers are worth comparing to.
_smart_menu_is_command_word() {
    local before="${LBUFFER%${LBUFFER##*[[:space:]]}}"
    [[ -n "${before//[[:space:]]/}" ]] || return 0
    # Nothing before a separator can make this a command position, so drop it:
    # that keeps the split below proportional to the command being typed, not
    # to the length of the line.
    before="${before##*[|;&]}"
    [[ -n "${before//[[:space:]]/}" ]] || return 0
    local -a bw
    # (z) splits into SHELL words rather than at every byte of whitespace, and it
    # keeps each word's original quoting. Both matter: a quoted argument stays
    # one word (so a wrapper name inside it cannot match the list below), and a
    # word that is quoted as a whole — `"sudo"` — does not match it either. Every
    # such case answers "not a command position", which is the pre-existing
    # behaviour, so the only positions this adds are the ordinary unquoted ones.
    # zsh never re-globs an expansion either way, so a `*` in the line stays a
    # character (asserted in tests/test-menu.zsh).
    bw=("${(@z)before}")
    local w
    for w in "${bw[@]}"; do
        case "$w" in
            *=*) ;;
            # The wrappers zsh itself keeps command completion for. Anything
            # that takes an option before its command (`sudo -u x git`, `nice
            # -n 10`) is not recognised, and falls through to the native grid.
            sudo|doas|command|builtin|exec|env|time|nohup|nice|ionice|setsid|stdbuf|noglob|watch) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# _smart_menu_lister -- normalise SMART_MENU_LISTER to `builtin` or `fzf-tab`.
#
# Normalising (rather than comparing the raw string everywhere) means the
# spelling `fzf_tab`, `fzf`, `external`, `none` or `off` all work, and a typo
# degrades to the safe default instead of silently disabling the popup.
#
# The accepted spellings are the block below, and they are hand-copied into the
# two case statements that need to enumerate them:
#   * _smart_menu_lister_recognised -- so an unrecognised value can be REPORTED
#     instead of quietly behaving like `builtin`
#   * smart-lister                  -- so a typo is an argument error, not a
#     status dump
# Here, only the fzf-tab side is listed: its `*)` fallback IS the builtin side,
# which is why "anything else means builtin" cannot drift out of step with the
# lists below. A unit test drives `smart-lister` with every spelling and asserts
# all three agree, because hand-copied lists are the one thing that can.
#
#   builtin : builtin smart internal native built-in on  yes true  1  (and unset/empty)
#   fzf-tab : fzf-tab fzf_tab fzf     ftb   external none off no  false 0
#
# `off`/`no`/`false`/`0` mean "OUR lister off" — i.e. handed to the other one —
# not "no list at all", which is what SMART_MENU=false is for.
_smart_menu_lister() {
    _smart_menu_lister_scan
    print -r -- "$_SMART_MENU_LISTER_RET"
    return 0
}

# The scan form exists because the popup gate runs this decision on EVERY
# keystroke, and `_smart_menu_lister`'s print costs a subshell fork. Same
# table, published through a global — _smart_menu_lister keeps the echo form
# for status output, doctor and tests.
typeset -g _SMART_MENU_LISTER_RET=''
_smart_menu_lister_scan() {
    case "${SMART_MENU_LISTER:-builtin}" in
        fzf-tab|fzf_tab|fzf|ftb|external|none|off|no|false|0)
            _SMART_MENU_LISTER_RET="fzf-tab" ;;
        *)
            _SMART_MENU_LISTER_RET="builtin" ;;
    esac
    return 0
}

# _smart_menu_lister_is_builtin -- 0 when this plugin owns the list.
_smart_menu_lister_is_builtin() {
    _smart_menu_lister_scan
    [[ "$_SMART_MENU_LISTER_RET" == "builtin" ]]
}

# _smart_menu_lister_recognised -- 0 when the raw value is a spelling we
# document. Used by the status output so an unrecognised value is REPORTED
# instead of quietly behaving like `builtin` (which looks like the switch
# "not working").
_smart_menu_lister_recognised() {
    case "${SMART_MENU_LISTER:-builtin}" in
        # builtin spellings
        builtin|smart|internal|native|built-in|on|yes|true|1) return 0 ;;
        # fzf-tab spellings
        fzf-tab|fzf_tab|fzf|ftb|external|none|off|no|false|0) return 0 ;;
        *) return 1 ;;
    esac
}

# _smart_menu_should_list -- all preconditions for running completion.
# _smart_menu_word_tail -- the part of the current word the user is still
# narrowing down: everything after the LAST '/'.
#
# WHY THIS EXISTS (and why the gate below measures it, not the whole word):
# `_smart_menu_word` returns the entire shell word, so typing `ls -la /etc/l`
# has a SIX-character word (`/etc/l`) that clears any sane minimum — yet the
# user has typed exactly one character of real input. Gating on the whole word
# is why every single keystroke of every path repainted the candidate grid,
# starting from the very first character after a '/' (the v2.2.9 report).
# The last segment is the only honest measure of "how much has been typed".
_smart_menu_word_tail() {
    local w
    w="$(_smart_menu_word)"
    print -r -- "${w##*/}"
}

_smart_menu_should_list() {
    _smart_menu_enabled || return 1
    # Handed to an external lister? Then there is no list for US to draw.
    # Checked early: it is a single string compare and it makes the log line
    # unambiguous ("nothing was drawn" has two very different causes).
    _smart_menu_lister_is_builtin || return 1
    # compsys has to be alive; otherwise there is nothing to list.
    (( ${+functions[_smart_native_have_compinit]} )) || return 1
    _smart_native_have_compinit || return 1

    local w w_tail min
    # Direct expansions, not $(_smart_menu_word) / $(_smart_menu_word_tail):
    # this gate runs once per keystroke, and each function-call form was
    # paying for a subshell fork on every one of them.
    w="${LBUFFER##*[[:space:]]}"
    # "How much has the user typed" is the LAST SEGMENT, not the whole word:
    # `/etc/l` is a six-character word but one character of input. See
    # _smart_menu_word_tail above.
    w_tail="${w##*/}"
    if _smart_menu_is_command_word; then
        min="${SMART_MENU_MIN_PREFIX_CMD:-2}"
    elif (( ${+functions[_smart_recent_cd_empty_ok]} )) && _smart_recent_cd_empty_ok; then
        # `cd ` / `pushd ` with recent dirs enabled: list immediately, because
        # "which directories have I been in?" is exactly the question being
        # asked there. Deliberately narrower than SMART_MENU_MIN_PREFIX=0,
        # which would dump every candidate after every space.
        min=0
    else
        # The inline ghost is NOT gated by either minimum: it suggests from the
        # FIRST character, so raising SMART_MENU_MIN_PREFIX only delays the list.
        min="${SMART_MENU_MIN_PREFIX:-2}"
    fi
    # PATH words list from the FIRST segment character (autocomplete parity):
    # `/u`, `~/l`, `/etc/l` pop the moment one real character is typed, not after
    # two. A bare `/` (or any trailing slash, e.g. `/usr/`) is the user asking
    # "what is in this directory?" — list it at once, do not wait for the next
    # keystroke. This overrides both MIN_PREFIX and MIN_PREFIX_CMD for paths;
    # non-path words (e.g. `git s`) keep their two-character gate (see e2e 12a).
    if [[ "$w" == */* ]]; then
        min=1
        (( ${#w_tail} == 0 )) && min=0
    fi
    (( ${#w_tail} >= min )) || return 1
    # The upper bound still guards the WHOLE word: that one is about how
    # expensive a single completion is, and a very long path is slow no matter
    # how little of its last segment has been typed.
    (( ${#w} <= ${SMART_MENU_MAX_PREFIX:-64} )) || return 1
    return 0
}

# ---------------------------------------------------------------------------
# The listing completion widget
# ---------------------------------------------------------------------------

# _smart_menu_decide_list <nmatches>
#
# Pure decision used by the listing widget: should the candidate list be drawn?
#   0 = draw the list
#   1 = suppress it
# A match count is suppressed when it is below SMART_MENU_MIN_MATCHES (a lone
# candidate is already shown as inline ghost text) or above SMART_MENU_MAX_MATCHES
# (a gigantic directory listing — suppress it so we never re-render thousands of
# rows on every keystroke). The cap is ALSO what keeps zsh's interactive
# "do you wish to see all N possibilities (M lines)?" confirmation from ever
# appearing: that prompt fires for lists longer than the screen, so simply never
# drawing such a list is the robust fix. (Scoping LISTMAX instead eats
# keystrokes — see the note at the top of this file.)
# Split out of the completer so it is unit-testable without a compsys/ZLE
# context (same idea as _smart_menu_note_cost).
_smart_menu_decide_list() {
    local n="$1"
    (( n >= ${SMART_MENU_MIN_MATCHES:-2} )) || return 1
    if (( ${SMART_MENU_MAX_MATCHES:-0} > 0 && n > ${SMART_MENU_MAX_MATCHES} )); then
        return 1
    fi
    return 0
}

# _smart_menu_list_main -- the completer function behind `zle -C`.
#
# Runs the user's normal completion, then takes control of the *display*:
#   decide-list says draw -> force the list, never insert
#   otherwise              -> suppress the list, never insert
# `compstate` is only writable from in here, which is exactly why the list is
# driven by a completion widget instead of calling `zle list-choices` naked.
#
# Single-column mode is OPT-IN (SMART_MENU_SINGLE_COLUMN=true; default false).
# Candidates are generated directly for the common cases (commands, filesystem
# paths, cd recent-directories) and painted one per line, because there is no
# reliable way to capture compsys' own matches (shadowing `compadd` with a
# function makes several zsh builds stop adding matches at all — measured).
#
# The price of generating them is why this is not the default: this branch
# never calls `_main_complete`, so it also drops the user's descriptions /
# list-colors / matcher-list (fuzzy) for those contexts, and every context it
# cannot generate falls through to the native grid below. That fall-through is
# exactly why the popup can change shape mid-typing.
_smart_menu_list_main() {
    compstate[insert]=''          # this channel only displays, never inserts

    if [[ "${SMART_MENU_SINGLE_COLUMN:-false}" == "true" ]]; then
        _smart_menu_candidates
        local _sc_n=$#_SMART_MENU_CAND
        if (( _sc_n >= ${SMART_MENU_MIN_MATCHES:-2} )) && \
           (( ${SMART_MENU_MAX_MATCHES:-0} == 0 || _sc_n <= ${SMART_MENU_MAX_MATCHES} )); then
            _smart_menu_draw_single
            _SMART_MENU_NMATCHES="$_sc_n"
            _SMART_MENU_LISTED=1
            _SMART_MENU_TRUNCATED=0
            return 0
        fi
        # generator produced nothing useful for this context -> native below
    fi

    # Native path (unchanged): rich, multi-column grid via the user's own
    # compsys. Used when single-column is off, or when the generator had no
    # candidates for this word (so the full completion still appears).
    _main_complete "$@"
    _SMART_MENU_NMATCHES="${compstate[nmatches]:-0}"
    if _smart_menu_decide_list "$_SMART_MENU_NMATCHES"; then
        compstate[list]='list'
        _SMART_MENU_LISTED=1
        _SMART_MENU_TRUNCATED=0
    else
        # Suppressed: either below the minimum (ghost takes over) or above the
        # cap (huge dir — the popup would be unreadable, and declining to draw
        # it is also what keeps zsh's "do you wish to see all N possibilities"
        # prompt out of the way). Note which, for status output.
        compstate[list]=''
        _SMART_MENU_LISTED=0
        if (( ${SMART_MENU_MAX_MATCHES:-0} > 0 && _SMART_MENU_NMATCHES > ${SMART_MENU_MAX_MATCHES} )); then
            _SMART_MENU_TRUNCATED=1
        else
            _SMART_MENU_TRUNCATED=0
        fi
    fi
    return 0
}
zle -C _smart_menu_list list-choices _smart_menu_list_main 2>/dev/null

# ---------------------------------------------------------------------------
# Single-column (vertical) candidate generation + rendering
# ---------------------------------------------------------------------------

# _smart_menu_candidates -- fill _SMART_MENU_CAND with the live-popup
# candidates for the current word, generated directly (no compadd shadowing).
#
# Covers the common cases:
#   * command position -> commands + functions + aliases + builtins
#     (prefix-filtered). That includes the words after `|`, `&&` and `;`, and
#     after a wrapper like `sudo`, because zsh completes commands there too.
#   * the first word after cd/pushd -> cd recent-directories (if enabled), with
#     an empty word and with a typed prefix
#   * path / argument -> filesystem glob of the current word
# Anything else (git subcommands, ssh hosts, option strings, …) yields an
# empty list here, which makes _smart_menu_list_main fall through to the
# native rich completion so those are still offered (multi-column).
_smart_menu_candidates() {
    local -a _sc_out
    local w _is_cmd=0
    # Direct expansion (same as _smart_menu_word): per-keystroke caller.
    w="${LBUFFER##*[[:space:]]}"
    _smart_menu_is_command_word && _is_cmd=1

    if (( _is_cmd )); then
        _sc_out=( ${(k)commands} ${(k)functions} ${(k)aliases} ${(k)builtins} )
        # `${(b)…}` for the same reason the path branch below uses it: the word
        # is USER INPUT feeding a pattern. EXTENDED_GLOB — which several popular
        # frameworks turn on — makes `#`, `^`, `(` and `<->` live pattern syntax
        # on top of `[ ] * ?`, so an unescaped prefix can match names the typed
        # text never contained, or be a bad pattern. With the escape, `git#`
        # means the command `git#`, and a command position that has no literal
        # match yields nothing and falls through to native, as it should.
        (( ${#w} > 0 )) && _sc_out=( ${(M)_sc_out:#${(b)w}*} )
    else
        # cd / pushd with an empty word: offer recent directories first.
        if (( ${#w} == 0 )) && (( ${+functions[_smart_recent_cd_empty_ok]} )) \
           && _smart_recent_cd_empty_ok; then
            _smart_recent_load 2>/dev/null
            _sc_out=( "${_SMART_RECENT_DIRS[@]}" )
        fi
        if (( ${#w} > 0 )); then
            # cd / pushd with a word already typed: the same recent directories,
            # prefix-matched. Without this the vertical list answers `cd Dow`
            # with files in the current directory while the native grid answers
            # it with ~/Documents — so the popup changed shape the moment the
            # user typed the first letter after `cd `.
            #
            # Only for a word that is not already an explicit path: `cd /et` is
            # the filesystem's question to answer, which is also what the
            # completer in lib/engine/recent.zsh decides.
            if (( ${+functions[_smart_recent_is_cd_arg]} )) \
               && _smart_recent_is_cd_arg "$LBUFFER" \
               && _smart_recent_enabled; then
                case "$w" in
                    /*|~*|./*|../*) ;;
                    *)
                        _smart_recent_load 2>/dev/null
                        local _sc_d
                        # Plain string prefixes, not patterns: neither the full
                        # path nor its last segment has to be escaped here, and
                        # that is worth the two comparisons.
                        for _sc_d in "${_SMART_RECENT_DIRS[@]}"; do
                            [[ "$_sc_d" == "$w"* || "${_sc_d:t}" == "$w"* ]] && \
                                _sc_out+=( "$_sc_d" )
                        done
                        ;;
                esac
            fi
            # The typed word is USER INPUT and must never reach the glob engine
            # raw. Typing `[` used to build the pattern `[*`, and a bad pattern
            # is not a nomatch: it ABORTS this function and prints
            # "bad pattern: [*" on every single keystroke.
            #   - `${(b)…}` escapes the pattern-special characters, so `[`, `]`,
            #     `*`, `?`, `#` are matched literally.
            #   - but `(b)` escapes `~` too, which would silently kill every
            #     `~/`-prefixed candidate (a very common prefix). So a leading
            #     `~/` is expanded RAW and only the remainder is escaped.
            #     (`${~x}` requires a VARIABLE — `${~'~/'}` is a bad
            #     substitution — hence the `_sc_t` holder.)
            #   - `~user` is deliberately NOT special-cased: it degrades to the
            #     native completion, which is better than emitting an
            #     unvalidated `~name` prefix into the pattern.
            local _sc_t='~/' _sc_pre='' _sc_pat="$w"
            if [[ "$w" == '~/'* ]]; then
                _sc_pre="${~_sc_t}"
                _sc_pat="${w#\~/}"
            fi
            _sc_out+=( ${~_sc_pre}${(b)_sc_pat}*(N) )
        elif (( ${#_sc_out} == 0 )); then
            _sc_out+=( *(N) )
        fi
    fi

    # de-duplicate (commands/functions/aliases overlap) and store.
    _SMART_MENU_CAND=( ${(@u)_sc_out} )
    return 0
}

# _smart_menu_single_display -- fill _SMART_MENU_DISP with the single-column
# display strings for _SMART_MENU_CAND, index-aligned with it.
#
# zsh's list renderer derives the column count from the widest DISPLAY string.
# Padding every display string to the full terminal width therefore forces
# exactly ONE column — that is the whole mechanism, and it is why this is a
# pure function (no compadd, no ZLE): the "one column" property is arithmetic
# and can be asserted without a terminal.
#
# NOTE: this is the ONLY place the popup's layout is decided. It never touches
# LISTMAX (see the warning at the top of this file) — padding the display
# strings is sufficient and does not corrupt ZLE's next input read.
_smart_menu_single_display() {
    # NOTE: the width is passed to ${(r.cols.. .)} BY NAME (cols), not via a
    # `pad="$cols"` alias. `local cols=$((...)) pad="$cols"` on one line is a
    # trap: the whole command's expansions happen BEFORE either assignment, so
    # `pad` ends up EMPTY and ${(r...)}, padding to width 0, quietly returns the
    # string unpadded — the popup then silently reverts to a multi-column grid.
    # (Measured; the unit test "padded to terminal width" is the regression.)
    local cols=$(( ${COLUMNS:-80} > 0 ? ${COLUMNS:-80} : 80 ))
    local x
    _SMART_MENU_DISP=()
    for x in "${_SMART_MENU_CAND[@]}"; do
        [[ -d "$x" ]] && x="${x}/"      # directories read better with a slash
        _SMART_MENU_DISP+=( "${(r.cols.. .)x}" )
    done
    return 0
}

# _smart_menu_draw_single -- paint _SMART_MENU_CAND one candidate per line.
#
# `-d` carries the padded display strings, so every row is exactly one
# candidate wide and zsh can only lay them out vertically.
_smart_menu_draw_single() {
    local -a cand=("${_SMART_MENU_CAND[@]}")
    _smart_menu_single_display
    compadd -d _SMART_MENU_DISP -a cand
    compstate[list]='list'
    return 0
}

# ---------------------------------------------------------------------------
# Completion-strategy probe (the `completion` half of SMART_SUGGEST_STRATEGY)
# ---------------------------------------------------------------------------

# _smart_menu_probe_main -- the completer behind the unambiguous-prefix probe.
#
# Runs the user's completion and lets zsh insert ONLY the unambiguous prefix
# (the part Tab would add before it had to choose). The caller then diffs
# $BUFFER to learn what completion proposed and reverts it, so the text becomes
# a *suggestion* rather than an edit.
#
# compstate[list] is cleared: this channel proposes text, it never paints a list
# (drawing belongs to _smart_menu_list, so the two can never fight over it).
_smart_menu_probe_main() {
    _main_complete "$@"
    compstate[insert]='unambiguous'
    compstate[list]=''
    return 0
}
zle -C _smart_menu_probe complete-word _smart_menu_probe_main 2>/dev/null

# The return slot of _smart_menu_probe_suffix. Declared here rather than left to
# the assignment below: a bare write to an undeclared name still creates a global
# (this file runs under `no_warn_create_global`), so without this line the global
# existed only as a side effect and was invisible to anything that reads
# declarations -- which is how it escaped every audit of the module's state.
typeset -g _SMART_PROBE_SUFFIX_RET=''

# _smart_menu_completion_suffix -- echo what completion would append, or "".
#
# MUST be called from inside a ZLE widget (it runs `zle`). Read-only with
# respect to the user's line: the buffer is restored before returning.
#
# REGRESSION NOTE (the "no hint while typing a path" bug): this function MUST
# NOT be called inside a command substitution `$( … )`. A `$( )` forks a
# subshell, and the `zle` builtin CANNOT run there — the probe silently did
# nothing, `after` stayed equal to `before`, and the completion fallback
# returned "" on every keystroke, for every user, since the day it shipped.
# Callers inside a widget must use `_smart_menu_probe_suffix` (global return,
# no fork); this printing wrapper is kept for tests and manual debugging.
_smart_menu_completion_suffix() {
    _smart_menu_probe_suffix
    print -r -- "${_SMART_PROBE_SUFFIX_RET:-}"
    return 0
}

# _smart_menu_probe_suffix -- the widget-context worker. Sets
# _SMART_PROBE_SUFFIX_RET to the unambiguous completion suffix ("" when none).
# Call DIRECTLY from a widget — never inside `$( )` (see the note above).
_smart_menu_probe_suffix() {
    _SMART_PROBE_SUFFIX_RET=""
    (( ${+widgets[_smart_menu_probe]} )) || return 0
    # Only meaningful at end of line — completion would replace the word under
    # the cursor, and we cannot express that as a pure suffix.
    (( CURSOR == ${#BUFFER} )) || return 0
    _smart_native_have_compinit 2>/dev/null || return 0

    local before="$BUFFER" cur="$CURSOR" after
    zle _smart_menu_probe 2>/dev/null
    after="$BUFFER"
    BUFFER="$before"          # this channel proposes, it never edits
    CURSOR="$cur"
    [[ "$after" == "$before"* ]] || return 0
    _SMART_PROBE_SUFFIX_RET="${after#$before}"
    return 0
}

# ---------------------------------------------------------------------------
# Tick — called by the event layer after every buffer edit
# ---------------------------------------------------------------------------

# _smart_menu_note_cost <cost-ms> -- apply the throttle policy to one listing.
#
# Split out of _smart_menu_tick so the policy is unit-testable: this is the rule
# that silently ate the popup (a 50ms threshold tripped by a one-off 180ms cold
# load, with a 3-edit cool-down), and an untestable rule is how it survived.
_smart_menu_note_cost() {
    local cost="$1" slow="${SMART_MENU_SLOW_MS:-250}" keys="${SMART_MENU_COOLDOWN_KEYS:-0}"
    _SMART_MENU_LAST_MS="$cost"
    if (( keys > 0 && slow > 0 && cost >= slow )); then
        _SMART_MENU_COOLDOWN="$keys"
        _smart_menu_dbg "list cost=${cost}ms SLOW -> cooldown=$keys"
        return 0
    fi
    _smart_menu_dbg "list cost=${cost}ms"
    return 0
}

# _smart_menu_tick
#
# ORDER IS LOAD-BEARING:
#   1. show the ghost (POSTDISPLAY + region_highlight) — the event layer has
#      already done it, but we re-assert it because a previous listing may have
#      dropped our region_highlight entry.
#   2. run the listing completion. Its redraw paints the line (ghost included)
#      and the candidate list in one go.
# Any redraw after step 2 deletes the list, so there is none.
#
# THROTTLING: measured cost is 10-30ms for every ordinary listing, so the
# throttle is OFF by default (SMART_MENU_COOLDOWN_KEYS=0) and the list always
# matches the current word. Enable it only for a persistently expensive
# completion: a listing at or above SMART_MENU_SLOW_MS then buys a cool-down of
# SMART_MENU_COOLDOWN_KEYS edits. Weigh the cost of skipping: the skipped edit
# does not repaint, so the list that was on screen is gone for that keystroke.
# The policy itself lives in _smart_menu_note_cost, above.
# NOTE ON ERASE-ONCE-DRAWN (measured, do not retry this)
#   Candidate rows are ORDINARY terminal output the moment they are printed:
#   verified against stock zsh (no plugin, plain `ls -la <Tab>`), the rows stay
#   under the line after every further keystroke, and in a short pane they have
#   already scrolled ABOVE the prompt. No redraw we can issue from a widget
#   removes them (`zle -R`, a suppressed re-listing, and terminfo's clear-to-
#   end-of-display were each measured; none moved a pixel).
#   So "the screen got noisy" has exactly one lever: DRAW FEWER LISTS. That is
#   what the two-character minimum below is for.
#   The ONE exception is the list that WE drew ourselves and that the next tick
#   declines to redraw — see _smart_menu_forget_rows, which is allowed exactly
#   one redraw to take it back.

# _smart_menu_forget_rows -- take back the candidate rows the last tick drew.
#
# WHY THIS EXISTS AT ALL
#   While the list keeps being drawn, zsh maintains the area under the line by
#   itself: narrowing `git st` -> `git sta` really does turn 3 rows into 2 with
#   no help from us. The one transition zsh never handles is the LAST one — the
#   tick where the listing is SUPPRESSED (compstate[list]=''). That path never
#   reaches zsh's list code, so the rows belonging to the previous prefix simply
#   stay: measured, 2 stale rows sitting under `git stat` while the ghost for
#   the single match is painted above them.
#
# WHY ONLY `zle -R "" ""` AND WHY ONLY SOMETIMES
#   Measured on the bytes zsh writes to a pty, one keystroke, two-line prompt:
#
#     zle -R               33 bytes, no vertical movement, does NOT clear
#     zle -R ""            33 bytes, no vertical movement, does NOT clear
#     zle -R "" ""         96 bytes, `\r\r\n '  ' ESC[A` + ESC[K, CLEARS
#     zle -R "" "" ""      98 bytes, same, CLEARS
#
#   Only the second argument (zsh's "more-specific display" prompt) makes zsh
#   recompute the prompt area, and that recomputation is what also wipes the
#   region below the line. It arrives with a newline, which SCROLLS the screen
#   whenever the prompt sits on the last row — the "typing one character starts
#   a new input line, without waiting for Enter" report. On every keystroke that
#   is a bug; once, at the moment the list disappears, it is exactly what zsh
#   itself does when it retires a list of its own.
#   So this is the only place in the plugin that asks for a full refresh, and
#   the flag makes sure it happens once per collapse, never per keystroke.
_smart_menu_forget_rows() {
    (( _SMART_MENU_ROWS )) || return 0
    _SMART_MENU_ROWS=0
    zle -R "" "" 2>/dev/null
    return 0
}

_smart_menu_tick() {
    _smart_menu_should_list || {
        # The guard matters: argument expansion happens BEFORE
        # _smart_menu_dbg's own early return, so an unguarded call would
        # still pay for the word/lister reads on every rejected keystroke.
        if [[ -n "${SMART_MENU_DEBUG:-}" ]]; then
            _smart_menu_lister_scan
            _smart_menu_dbg "skip gate word=[${LBUFFER##*[[:space:]]}] lister=$_SMART_MENU_LISTER_RET"
        fi
        # The gate can close while rows from the previous prefix are on screen
        # (backspacing `git st` back to `git s` drops below the minimum). Nothing
        # else will remove them, so hand them back here too.
        _smart_menu_forget_rows
        return 0
    }

    # Fallback for the completer wiring: if the bootstrap precmd ran before the
    # user's compinit (some plugin managers load us first), join the chain now —
    # we are provably inside the completion path, so compsys is alive.
    # One integer test per tick; the install itself is idempotent.
    if (( ${+functions[_smart_recent_install]} )) && (( ! ${_SMART_RECENT_INSTALLED:-0} )); then
        _smart_recent_install 2>/dev/null
    fi

    if (( _SMART_MENU_COOLDOWN > 0 )); then
        (( _SMART_MENU_COOLDOWN-- ))
        (( _SMART_MENU_SKIPS++ ))
        _smart_menu_dbg "skip cooldown left=$_SMART_MENU_COOLDOWN word=[${LBUFFER##*[[:space:]]}]"
        # A skipped edit draws nothing, so the list on screen is stale for this
        # keystroke; if we do not retire it here it never goes away.
        _smart_menu_forget_rows
        return 0
    fi

    (( ++_SMART_MENU_TICKS ))
    _smart_display_show 2>/dev/null

    local t0=""
    # Fork-free clock read; the printing form would cost a subshell per call
    # and this path runs on every keystroke that reaches the listing.
    _smart_menu_now_ms_scan && t0="$_SMART_MENU_NOW_MS"
    _SMART_MENU_LISTED=0
    # NOTE: no LISTMAX juggling here. It used to be scoped to -1 around this
    # call to suppress zsh's "do you wish to see all N possibilities" prompt;
    # that corrupts ZLE's next input read and eats one keystroke per listing.
    # The prompt is prevented by SMART_MENU_MAX_MATCHES instead (see above).
    zle _smart_menu_list 2>/dev/null
    # Drawing a list makes zsh refresh the line for it, and that refresh rewrites
    # region_highlight with entries that reach into POSTDISPLAY clipped back to
    # the end of BUFFER (measured: `5 10` -> `5 5`, i.e. zero-length = no colour).
    # Put our entry back from the CURRENT POSTDISPLAY so this widget's final
    # repaint still colours the ghost. NO `zle -R` here — a redraw would erase
    # the list we just drew.
    _smart_display_reassert_rh 2>/dev/null
    (( _SMART_MENU_LISTED )) || {
        # Nothing was drawn. Report WHICH gate refused: "below the minimum" and
        # "over the cap" look identical on screen but have opposite fixes, and
        # conflating them in the log (as this used to) misleads debugging.
        if (( ${_SMART_MENU_TRUNCATED:-0} == 1 )); then
            _smart_menu_dbg "list n=${_SMART_MENU_NMATCHES} over cap=${SMART_MENU_MAX_MATCHES:-0} -> no list"
        else
            _smart_menu_dbg "list n=${_SMART_MENU_NMATCHES} below min=${SMART_MENU_MIN_MATCHES:-2} -> no list"
        fi
        # This tick drew nothing. If the PREVIOUS one drew rows they are STILL
        # on screen (zsh only maintains that area while it is drawing a list),
        # and they now describe an older, longer prefix — the single-match
        # transition is exactly this case, and it is why the ghost would
        # otherwise sit under the wrong candidate list. Retire them. The gate
        # below still exists to keep this rare: ONE redraw per collapse, not one
        # per keystroke. See _smart_menu_forget_rows.
        _smart_menu_forget_rows
        return 0
    }
    # Rows are on the screen and belong to the current word; the next tick that
    # draws nothing is the one that has to take them back.
    _SMART_MENU_ROWS=1
    if [[ -n "$t0" ]]; then
        _smart_menu_now_ms_scan
        _smart_menu_note_cost $(( _SMART_MENU_NOW_MS - t0 ))
    fi
    return 0
}

# _smart_menu_clear -- drop the candidate-list bookkeeping.
#
# This is BOOKKEEPING ONLY: it never redraws. Callers that actually have to take
# rows off the screen must call _smart_menu_forget_rows FIRST (it reads
# _SMART_MENU_ROWS, which this resets). Every caller either does that or is
# about to reset the whole screen anyway (`smart-menu off`, `smart-lister`) or
# re-tick immediately (accept-word).
_smart_menu_clear() {
    _SMART_MENU_LISTED=0
    _SMART_MENU_NMATCHES=0
    # Zeroed on purpose: after this call nobody may issue a redraw for rows that
    # belong to a prefix that is gone.
    _SMART_MENU_ROWS=0
    return 0
}

# ---------------------------------------------------------------------------
# Runtime CLI
# ---------------------------------------------------------------------------
smart-menu() {
    case "${1:-status}" in
        on|enable|1|true)
            SMART_MENU=true
            print -r -- "smart-menu: on (min prefix: cmd=${SMART_MENU_MIN_PREFIX_CMD} arg=${SMART_MENU_MIN_PREFIX}, min matches=${SMART_MENU_MIN_MATCHES})"
            ;;
        off|disable|0|false)
            SMART_MENU=false
            _smart_menu_clear
            _smart_display_clear 2>/dev/null
            zle -R 2>/dev/null
            print -r -- "smart-menu: off (inline suggestion is unaffected)"
            ;;
        toggle)
            if _smart_menu_enabled; then smart-menu off; else smart-menu on; fi
            ;;
        status|*)
            if _smart_menu_enabled; then
                print -r -- "smart-menu: on"
            else
                print -r -- "smart-menu: off"
            fi
            print -r -- "  min prefix (command/arg): ${SMART_MENU_MIN_PREFIX_CMD}/${SMART_MENU_MIN_PREFIX}"
            print -r -- "  min matches:              ${SMART_MENU_MIN_MATCHES}"
            print -r -- "  max matches (cap):        ${SMART_MENU_MAX_MATCHES:-0}$( (( ${SMART_MENU_MAX_MATCHES:-0} == 0 )) && print -r -- ' (uncapped)' || print -r -- ' (bigger lists are suppressed)')"
            if [[ "$(_smart_menu_lister)" == "builtin" ]]; then
                print -r -- "  lister:                   builtin (this plugin draws the list)"
            else
                print -r -- "  lister:                   fzf-tab (we draw nothing — an external picker owns the list)"
            fi
            if ! _smart_menu_lister_recognised; then
                print -r -- "  note:                     SMART_MENU_LISTER='${SMART_MENU_LISTER}' is not a known value — behaving as 'builtin'"
            fi
            if [[ "${SMART_MENU_SINGLE_COLUMN:-false}" == "true" ]]; then
                print -r -- "  layout:                   single column (one candidate per line)"
            else
                print -r -- "  layout:                   native multi-column grid"
            fi
            if [[ "${SMART_MENU_HISTORY_KEYS:-false}" == "true" ]]; then
                print -r -- "  history keys:             on (↑/↓ prefix-search history when the line is non-empty)"
            else
                print -r -- "  history keys:             off (↑/↓ keep native history navigation)"
            fi
            if (( ${SMART_MENU_COOLDOWN_KEYS:-0} > 0 )); then
                print -r -- "  throttle:                 on (slow >= ${SMART_MENU_SLOW_MS}ms -> skip ${SMART_MENU_COOLDOWN_KEYS})"
            else
                print -r -- "  throttle:                 off (list always matches the current word)"
            fi
            print -r -- "  last listing:             matches=${_SMART_MENU_NMATCHES} listed=${_SMART_MENU_LISTED} cost=${_SMART_MENU_LAST_MS}ms"
            # rows=1 means candidate rows are still on the screen and the next
            # tick that draws nothing will retire them. Surfaces the one piece of
            # screen state the plugin keeps, which is otherwise invisible.
            print -r -- "  candidate rows on screen: ${_SMART_MENU_ROWS}"
            if (( ${_SMART_MENU_TRUNCATED:-0} == 1 )); then
                print -r -- "  note:                    last popup suppressed (matches > SMART_MENU_MAX_MATCHES)"
            fi
            print -r -- "  listings/skipped:         ${_SMART_MENU_TICKS}/${_SMART_MENU_SKIPS}"
            ;;
    esac
    return 0
}

# _smart_menu_lister_status -- print the current owner. Split out so the
# argument error path can show it too (without duplicating the text).
_smart_menu_lister_status() {
    if [[ "$(_smart_menu_lister)" == "builtin" ]]; then
        print -r -- "smart-lister: builtin"
        print -r -- "  this plugin drives zsh's list; SMART_MENU specifies on/off."
    else
        print -r -- "smart-lister: fzf-tab"
        print -r -- "  this plugin draws no list; an external floating picker must."
    fi
    if ! _smart_menu_lister_recognised; then
        print -r -- "  note: SMART_MENU_LISTER='${SMART_MENU_LISTER}' is not a known value — behaving as 'builtin'"
    fi
    print -r -- "  switch with: smart-lister builtin | fzf-tab"
    return 0
}

# smart-lister -- choose which lister draws the candidate list.
#
# Same rationale as SMART_MENU_LISTER, but switchable in a running shell, which
# is what you want while diagnosing "two boxes": flip it, retype, and see which
# one stays. `builtin` re-arms the popup immediately; `fzf-tab` clears whatever
# we drew so no stale box is left behind.
smart-lister() {
    local arg="${1:-status}"
    case "$arg" in
        # --- builtin spellings (see the list above _smart_menu_lister) ---
        builtin|smart|internal|native|built-in|on|yes|true|1)
            SMART_MENU_LISTER=builtin
            export SMART_MENU_LISTER
            print -r -- "smart-lister: builtin — this plugin draws the candidate list"
            ;;
        # --- fzf-tab spellings ---
        fzf-tab|fzf_tab|fzf|ftb|external|none|off|no|false|0)
            SMART_MENU_LISTER=fzf-tab
            export SMART_MENU_LISTER
            # Drop anything we already drew: switching owner must not leave our
            # old list on screen, or the switch looks like it did nothing.
            _smart_menu_clear 2>/dev/null
            zle -R 2>/dev/null
            print -r -- "smart-lister: fzf-tab — we draw nothing; an external picker owns the list"
            print -r -- "              (inline grey suggestion is unaffected; run smart-doctor if no list appears)"
            ;;
        status)
            _smart_menu_lister_status
            ;;
        *)
            # A typo used to fall through to the status output, so
            # `smart-lister fzf-tb` looked like it had worked. Say so instead.
            print -ru2 -- "smart-lister: '$arg' is not a known value (expected: builtin | fzf-tab)"
            _smart_menu_lister_status
            return 1
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# smart-doctor -- "something else is drawing my list"
# ---------------------------------------------------------------------------
# When two candidate lists appear at once, the hard part is not the fix: it is
# working out WHICH code drew the second one. Every lister in this ecosystem
# leaves a fingerprint in the running shell and each one is a single cheap
# test, so this PRINTS them instead of guessing. "There are two listers" becomes
# something you can read off, not argue about.
#
# KEY IDEA: this plugin never replaces zsh's completion entry points. We add a
# `zstyle` completer (for `cd ` recent dirs) and our own `zle -C` listing
# widget; `_main_complete` and `compadd` stay STOCK. Those two are autoloaded
# stubs (`builtin autoload -XU`) in a normal shell, so if either is a real
# function body then SOMETHING ELSE is hooking completion — and a hijacked
# completion entry point is the usual source of a second popup.
#
# READ-ONLY on purpose: it changes no state and runs no completion, so it is
# safe in a half-broken shell and its output can be pasted whole into a report.
smart-doctor() {
    emulate -L zsh
    setopt localoptions extended_glob
    local n_foreign=0 fn body st km w
    local -a hits
    # Set when SMART_MENU_LISTER handed the list to a picker that is not loaded.
    # This outranks every other verdict: it means NO list is drawn at all, which
    # is a worse state than the two-list problem the doctor usually explains.
    local handover_broken=0

    print -r -- "zsh-smart-complete doctor"
    print -r -- "  zsh ${ZSH_VERSION}   term ${TERM:-?}   ${COLUMNS:-?}x${LINES:-?}"
    print -r -- ""

    # --- 1. completion entry points ----------------------------------------
    print -r -- "1. completion entry points (stock reads as 'builtin autoload')"
    for fn in _main_complete compadd _complete; do
        if (( ! ${+functions[$fn]} )); then
            # `compadd` is a BUILTIN (only callable from inside a completion
            # widget), so being absent from `functions` is the healthy state.
            # It appears there only when a plugin has shadowed it with a
            # function — which is fzf-tab's signature.
            if [[ "$fn" == compadd ]]; then
                print -r -- "   ok   ${fn} -- untouched builtin"
            else
                print -r -- "   .    ${fn} -- absent (compinit has not run yet)"
            fi
            continue
        fi
        body="${functions[$fn]}"
        if [[ "$body" == *autoload* ]]; then
            print -r -- "   ok   ${fn} -- stock"
        else
            print -r -- "   [!]  ${fn} -- REDEFINED: ${${body//$'\n'/ }[1,64]}"
            n_foreign=$(( n_foreign + 1 ))
        fi
    done

    # --- 2. known listers, by function-name fingerprint --------------------
    print -r -- ""
    print -r -- "2. other listers loaded in this shell"
    # Named with our own prefix, and unfunctioned at the end of this command:
    # a function defined inside a zsh function becomes GLOBAL, so without that
    # cleanup a plain `smart-doctor` would leave it in the user's shell.
    _smart_doc_prefix() {   # <label> <name-prefix>
        local -a h=( ${(M)${(k)functions}:#${2}*} )
        if (( ${#h} )); then
            print -r -- "   [!]  ${1} -- ${#h} function(s), e.g. ${h[1]}"
            return 1
        fi
        print -r -- "   ok   ${1} -- absent"
        return 0
    }
    _smart_doc_prefix "zsh-autocomplete"        "_autocomplete__"      || n_foreign=$(( n_foreign + 1 ))
    _smart_doc_prefix "zsh-autosuggestions"     "_zsh_autosuggest_"    || n_foreign=$(( n_foreign + 1 ))
    _smart_doc_prefix "fzf-tab"                 "_ftb"                 || n_foreign=$(( n_foreign + 1 ))
    _smart_doc_prefix "syntax-highlighting"     "_zsh_highlight"       || n_foreign=$(( n_foreign + 1 ))
    # A widget is how the completion UI usually takes over the key.
    # Only OUR widget and foreign completers are interesting here; zsh's own
    # `expand-or-complete` lives in every shell and would just be noise.
    for w in fzf-tab-complete _smart_menu_list _autocomplete__complete; do
        (( ${+widgets[$w]} )) && print -r -- "   widget registered: ${w}"
    done

    # --- 3. who owns Tab ---------------------------------------------------
    print -r -- ""
    print -r -- "3. Tab (^I) binding per keymap"
    for km in emacs viins main; do
        w="$(bindkey -M "$km" '^I' 2>/dev/null)"
        w="${w##* }"; w="${w//\"/}"
        print -r -- "   ${km} -> ${w:-(unbound)}"
    done

    # --- 4. zstyles that can enable a list ---------------------------------
    print -r -- ""
    print -r -- "4. zstyles that can put a list on screen"
    for st in menu completer matcher-list list-colors; do
        local -a v=()
        zstyle -a ":completion:*" "$st" v 2>/dev/null
        if (( ${#v} )); then
            print -r -- "   ${st} = ${(j:|:)v}"
        else
            print -r -- "   ${st} = (unset)"
        fi
    done

    # --- 5. our own side ---------------------------------------------------
    print -r -- ""
    print -r -- "5. zsh-smart-complete"
    local _lister; _lister="$(_smart_menu_lister)"
    print -r -- "   lister: SMART_MENU_LISTER=${SMART_MENU_LISTER:-builtin} -> ${_lister}"
    if ! _smart_menu_lister_recognised; then
        print -r -- "   [!]  that value is not recognised — behaving as 'builtin'"
    fi
    if [[ "$_lister" == "fzf-tab" ]]; then
        # The switch makes US stop listing, so it is only correct if something
        # else IS listing. Checked here rather than at load time on purpose:
        # with `zinit wait lucid` we are usually sourced BEFORE the other
        # plugin, so a load-time check would report a false negative.
        if (( ${+functions[_ftb_complete]} )) || (( ${+widgets[fzf-tab-complete]} )); then
            print -r -- "   ok   handed over, and fzf-tab looks loaded"
        else
            print -r -- "   [!]  handed over to fzf-tab, but fzf-tab is NOT loaded in this"
            print -r -- "        shell — NOTHING will draw a candidate list. Either load"
            print -r -- "        fzf-tab, or run: smart-lister builtin"
            handover_broken=1
        fi
    fi
    if (( ${+widgets[_smart_menu_list]} )); then
        print -r -- "   ok   listing widget registered"
    else
        print -r -- "   [!]  listing widget NOT registered (module not loaded?)"
    fi
    print -r -- "   SMART_MENU=${SMART_MENU:-true}  SMART_MENU_SINGLE_COLUMN=${SMART_MENU_SINGLE_COLUMN:-false}  SMART_NATIVE_MENU_SELECT=${SMART_NATIVE_MENU_SELECT:-false}"
    if (( ${+widgets[_smart_menu_list]} )); then
        print -r -- "   last listing: matches=${_SMART_MENU_NMATCHES} listed=${_SMART_MENU_LISTED} ticks=${_SMART_MENU_TICKS}"
    fi

    # --- 6. verdict --------------------------------------------------------
    print -r -- ""
    if (( handover_broken )); then
        print -r -- "VERDICT: no candidate list will be drawn at all — the list was handed"
        print -r -- "         to an external picker that is not loaded. Fix with either:"
        print -r -- "           smart-lister builtin      (take it back)"
        print -r -- "           load fzf-tab              (give the picker something to run)"
    elif (( n_foreign == 0 )); then
        print -r -- "VERDICT: only zsh's own completion and this plugin are in play."
        print -r -- "         If two lists still appear, the second one is NOT coming"
        print -r -- "         from the completion system (see section 3: another widget"
        print -r -- "         may own Tab)."
    else
        print -r -- "VERDICT: ${n_foreign} foreign completion hook(s) found above."
        print -r -- "         Each can draw a list of its own. That is the first place"
        print -r -- "         to look for a second popup: disable one and retype."
        print -r -- "         ('smart-menu off' isolates this plugin's side.)"
    fi
    print -r -- ""
    print -r -- "Note: this plugin NEVER redefines _main_complete/compadd, so a stock"
    print -r -- "      entry point above is the expected, healthy result."
    unfunction _smart_doc_prefix 2>/dev/null
    return 0
}
