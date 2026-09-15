# lib/engine/recent.zsh
#
# Recent-directory candidates for the completion menu ("recent-paths").
#
# This is the one feature worth taking from zsh-autocomplete — and the cheapest,
# because zsh already ships every hard part:
#
#   collection  `chpwd_recent_dirs` (a chpwd hook) appends every directory you
#               cd into to a file; `chpwd_recent_filehandler` reads it back.
#   display     zsh's own `_tilde` completes `~[1]`, `~[2]`, … once
#               `zsh_directory_name_cdr` is registered in
#               $zsh_directory_name_functions.
#
# What zsh does NOT do is offer those directories when you complete a plain
# `cd <word>`: `_cd` only looks at the filesystem, $cdpath and the directory
# stack. That gap is the entire reason this module exists, and it is closed by
# registering one completer.
#
# DESIGN RULES
#   * We never WRITE the database. No chpwd hook, no file of our own — we only
#     consume the standard one. If the user has never enabled collection the
#     list is empty and nothing else about their shell changes.
#   * We never REPLACE a completer. Ours is placed FIRST so it runs before
#     `_complete` (which returns 0 the moment it has a candidate, ending the
#     chain — a completer placed after it would never be reached), and it
#     always returns 1, so every other completer still contributes.
#   * Uninstalling restores the completer chain exactly as it was found —
#     including the case where the user had no `completer` zstyle at all.
#
# This module knows about config, state and compsys. It does NOT know about
# history, ranking, the inline suggestion, or ZLE rendering.

emulate -L zsh
setopt extended_glob no_warn_create_global

# Most-recent-first, de-duplicated. Filled by _smart_recent_load.
typeset -gaU _SMART_RECENT_DIRS=()

# The completer list we found before installing ourselves, whether the user's
# own `zstyle ':completion:*' completer` had defined it at all (if not, the
# built-in default `_complete _ignored` was in force and uninstalling must go
# back to *no* zstyle, not to a hard-coded copy), plus a flag. The flag — not
# the array's content — is the "are we installed" sentinel: a pre-set/empty
# saved array must never be mistaken for "already installed".
typeset -ga _SMART_RECENT_SAVED=()
typeset -gi _SMART_RECENT_HAD_STYLE=0
typeset -gi _SMART_RECENT_INSTALLED=0

# ---------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------

_smart_recent_enabled() {
    case "${SMART_RECENT_PATHS:-true}" in false|no|off|0|disabled) return 1 ;; esac
    (( ${_SMART_STATE[enabled]:-1} == 1 )) || return 1
    return 0
}

# _smart_recent_files -- echo one database path per line.
#
# Honours `zstyle ':chpwd:' recent-dirs-file` exactly like the stock reader
# (including its "+" placeholder for the default path). When the user has not
# set the style we also look at the XDG location, because that is where
# zsh-autocomplete — and anyone else following the XDG spec — records.
_smart_recent_files() {
    local -a files=()
    local dflt="${ZDOTDIR:-$HOME}/.chpwd-recent-dirs"
    zstyle -a ':chpwd:' recent-dirs-file files 2>/dev/null
    if (( ${#files} )); then
        files=(${files//(#s)+(#e)/$dflt})
    else
        files=("$dflt")
        local xdg="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/chpwd-recent-dirs"
        [[ -r "$xdg" ]] && files+=("$xdg")
    fi
    print -rl -- "${files[@]}"
    return 0
}

# _smart_recent_load -- read the database into $_SMART_RECENT_DIRS.
#
# Format is one `$'...'`-quoted path per line (written by
# `chpwd_recent_filehandler` with `print -rl ${(qqqq)argv}`), so the parse is
# split-then-unquote. Verified against paths containing spaces, single quotes
# and newlines.
#
# Only directories that still exist are kept: a deleted project must not sit in
# the menu as a candidate that errors when accepted.
_smart_recent_load() {
    _SMART_RECENT_DIRS=()
    local -a files=("${(@f)$(_smart_recent_files)}")
    local f line d
    local -a parts
    for f in "${files[@]}"; do
        [[ -r "$f" ]] || continue
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            parts=(${(z)line})
            d="${(Q)${parts[1]}}"
            [[ -n "$d" && -d "$d" ]] || continue
            _SMART_RECENT_DIRS+=("$d")
        done < "$f"
    done
    local max="${SMART_RECENT_PATHS_MAX:-20}"
    if (( max > 0 && ${#_SMART_RECENT_DIRS} > max )); then
        _SMART_RECENT_DIRS=("${_SMART_RECENT_DIRS[@]:0:$max}")
    fi
    return 0
}

# ---------------------------------------------------------------------------
# "Are we completing the first argument of cd?"
# ---------------------------------------------------------------------------

# _smart_recent_is_cd_arg <left-buffer>
#
# Pure (the left buffer is an argument, not a global) so it is unit-testable
# without a live ZLE.
#
# Rejects two cases that matter:
#   * no space yet  -> we are still completing the command word itself
#   * a SECOND word -> `cd old new` is a substring substitution, not a path, and
#                      its first argument must not be completed from history
_smart_recent_is_cd_arg() {
    local lb="$1"
    [[ "$lb" == *[[:space:]]* ]] || return 1
    local cmd="${lb%%[[:space:]]*}"
    local rest="${lb#*[[:space:]]}"
    [[ "$rest" == *[[:space:]]* ]] && return 1
    # ${cmd:t} so an explicit path (`/usr/bin/cd`) still matches.
    case "${cmd:t}" in cd|pushd|chdir) return 0 ;; esac
    return 1
}

# _smart_recent_cd_empty_ok -- may the popup open on an EMPTY word?
#
# Only straight after `cd ` / `pushd `, and only with the feature on. That is
# the one place where a list of recent directories is what you actually want,
# and exactly where stock zsh shows nothing until you press Tab. Every other
# empty word keeps SMART_MENU_MIN_PREFIX semantics (no list).
#
# Reads $LBUFFER: call ONLY from a ZLE context (the tick).
_smart_recent_cd_empty_ok() {
    _smart_recent_enabled || return 1
    _smart_recent_is_cd_arg "$LBUFFER"
}

# ---------------------------------------------------------------------------
# The completer
# ---------------------------------------------------------------------------

# _smart_recent_paths -- called by _main_complete as part of the completer chain.
#
# Returns 1 (never 0): we contribute candidates but never claim the completion,
# so the user's own completers keep running and their candidates keep appearing
# alongside ours.
#
# `compadd -P <dir>/ -- <base>` is what makes this work with a partial word:
# zsh matches the typed PREFIX against the BASENAME, so `tongji` finds
# `/Users/me/sites/tongji`, while the text inserted into the line is the full
# path. `-V name` keeps the list in recency order (the group is not sorted),
# and `-ld displ` shows the full path next to the basename that was matched.
_smart_recent_paths() {
    _smart_recent_enabled || return 1
    _smart_recent_is_cd_arg "$LBUFFER" || return 1
    # An explicit path is the filesystem completer's job — recent entries only
    # get in the way of `cd ~/…` or `cd ./…`.
    case "$PREFIX" in
        /*|~*|./*|../*) return 1 ;;
    esac

    _smart_recent_load
    (( ${#_SMART_RECENT_DIRS} )) || return 1

    local d base
    local -a displ
    for d in "${_SMART_RECENT_DIRS[@]}"; do
        base="${d:t}"
        [[ -n "$base" ]] || continue
        displ=("$d")
        compadd -V recent-directories -ld displ -P "${d:h}/" -- "$base"
    done
    return 1
}

# ---------------------------------------------------------------------------
# Install / uninstall
# ---------------------------------------------------------------------------

# _smart_recent_install -- put ourselves first in the completion chain.
#
# HOW THE CHAIN IS ACTUALLY CONFIGURED (this cost a real debugging round):
# there is NO `$completer` array to append to. `_main_complete` does
#
#     zstyle -a ":completion:${curcontext}:" completer _completers ||
#         _completers=( _complete _ignored )
#
# — i.e. the list comes from `zstyle ':completion:*' completer`, and an
# undefined $completer variable means nothing at all (the built-in default is
# used). Setting $completer therefore looks wired up and silently does nothing.
#
# Ours must be FIRST: `_complete` returns 0 as soon as it has a candidate and
# the loop stops there, so a completer placed after it would never run. We save
# what we found — including whether the style existed — so uninstall restores
# either the user's exact list or *no* style (back to the built-in default),
# never a hard-coded approximation of it.
#
# Must run after the user's compinit and after their own completion config:
# zstyle definitions are last-write-wins, so installing earlier would let a
# later user setting silently drop us.
_smart_recent_install() {
    _smart_recent_enabled || return 0
    (( _SMART_RECENT_INSTALLED )) && return 0

    # No compinit -> no chain to join. Not an error: the menu channel is inert
    # in that case anyway.
    if (( ${+functions[_smart_native_have_compinit]} )); then
        _smart_native_have_compinit || return 0
    fi

    local -a cur=()
    _SMART_RECENT_HAD_STYLE=0
    zstyle -a ':completion:*' completer cur 2>/dev/null && _SMART_RECENT_HAD_STYLE=1
    (( ${#cur} )) || cur=( _complete _ignored )

    # Already in the chain (re-source, or a user who configured it by hand):
    # adopt it rather than adding a second copy, and remember the value we saw
    # so uninstall restores exactly that.
    if (( ${cur[(I)_smart_recent_paths]} )); then
        _SMART_RECENT_SAVED=("${cur[@]}")
        _SMART_RECENT_HAD_STYLE=1
        _SMART_RECENT_INSTALLED=1
        return 0
    fi

    _SMART_RECENT_SAVED=("${cur[@]}")
    zstyle ':completion:*' completer _smart_recent_paths "${cur[@]}"
    _SMART_RECENT_INSTALLED=1
    return 0
}

# _smart_recent_uninstall -- restore the completer chain exactly as we found it.
_smart_recent_uninstall() {
    (( _SMART_RECENT_INSTALLED )) || return 0
    if (( ${_SMART_RECENT_HAD_STYLE:-0} )); then
        zstyle ':completion:*' completer "${_SMART_RECENT_SAVED[@]}"
    else
        # No style of the user's own: remove ours so the built-in default is
        # back in force.
        zstyle -d ':completion:*' completer
    fi
    _SMART_RECENT_SAVED=()
    _SMART_RECENT_HAD_STYLE=0
    _SMART_RECENT_INSTALLED=0
    return 0
}

# ---------------------------------------------------------------------------
# Runtime CLI
# ---------------------------------------------------------------------------
smart-recent() {
    case "${1:-status}" in
        on|enable|1|true)
            SMART_RECENT_PATHS=true
            _smart_recent_install
            print -r -- "smart-recent: on"
            ;;
        off|disable|0|false)
            SMART_RECENT_PATHS=false
            _smart_recent_uninstall
            print -r -- "smart-recent: off (completer chain restored)"
            ;;
        toggle)
            if _smart_recent_enabled; then smart-recent off; else smart-recent on; fi
            ;;
        status|*)
            if _smart_recent_enabled; then
                print -r -- "smart-recent: on"
            else
                print -r -- "smart-recent: off"
            fi
            local -a chain=()
            zstyle -a ':completion:*' completer chain 2>/dev/null
            (( ${#chain} )) || chain=( _complete _ignored )
            print -r -- "  completer chain:          ${(j: :)chain}"
            print -r -- "  in the chain:             $(( ${chain[(I)_smart_recent_paths]} > 0 ))"
            print -r -- "  max entries:              ${SMART_RECENT_PATHS_MAX:-20}"
            local f
            for f in "${(@f)$(_smart_recent_files)}"; do
                if [[ -r "$f" ]]; then
                    print -r -- "  database (readable):      $f"
                else
                    print -r -- "  database (missing):       $f"
                fi
            done
            _smart_recent_load
            print -r -- "  usable entries:           ${#_SMART_RECENT_DIRS}"
            if (( ${#_SMART_RECENT_DIRS} == 0 )); then
                print -r -- "  note:                     no recent dirs recorded yet — see README (chpwd_recent_dirs)"
            fi
            ;;
    esac
    return 0
}
