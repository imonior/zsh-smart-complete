# ---------------------------------------------------------------------------
# Shared installer core -- spliced verbatim into install.sh and
# install-entware.sh by tools/build-installers.sh, which is what lets both
# installers stay standalone files for `curl -fsSL ... | bash`.
#
#   * Never edit the generated block inside an installer: edit this file, run
#     tools/build-installers.sh, commit both artifacts. CI runs
#     tools/build-installers.sh --check, which fails when they disagree.
#   * Everything here has to run under the bash macOS still ships (3.2): no
#     `declare -A`, and no bare "${array[@]}" under `set -u`.
#   * A function belongs here only while its body is identical in both
#     installers. Anything environment-specific -- opkg paths, package names,
#     the message catalog, the wording of a question -- stays in the installer
#     that needs it. The generator cannot merge a divergence, and
#     tests/test-installer-shared.sh is where the ones that exist are listed.
# ---------------------------------------------------------------------------

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# Read from /dev/tty when available (fixes SSH sessions where stdin is not a tty
# but the controlling terminal is still /dev/tty - curl installers need it).
# Falls back to stdin when /dev/tty is unavailable or read fails.
_tty_read() {
    # Read using the caller's exact options/variable, passed through verbatim via
    # "$@". Do NOT join args into a string and re-split (e.g. `read $_args`):
    # this script sets `IFS=$'\n\t'` at the top (no space), so an unquoted
    # expansion would NOT word-split and `read` would receive one bogus
    # "-r -n 1 REPLY" option and abort with `read: -: invalid option`.
    # Prefer stdin when it is a tty; otherwise fall back to /dev/tty.
    if [[ -t 0 ]]; then
        read "$@" && return 0
        REPLY=""; return 1
    fi
    # Otherwise stdin is a pipe/file; try the controlling terminal /dev/tty
    # (e.g. `curl ... | bash`). No timeout — block until the user answers.
    if [[ -c /dev/tty ]] && read "$@" </dev/tty 2>/dev/null; then
        return 0
    fi
    # Last resort: stdin (may be EOF in non-interactive contexts → default).
    if read "$@" 2>/dev/null; then
        return 0
    fi
    REPLY=""; return 1
}

# 取一条本地化文案并插值；键不存在时原样输出（回退英文键名）。
msg() {
    local key="$1"; shift || true
    local t; t="$(_msg "$key")"
    [[ -z "$t" ]] && t="$key"
    # shellcheck disable=SC2059
    printf "$t\n" "$@"
}

select_language() {
    local REPLY=""
    case "${SMART_INSTALL_LANG:-}" in
        en|english|English) LANG_CODE="en" ;;
        zh-CN|zh_CN|zh|cn)  LANG_CODE="zh-CN" ;;
        zh-TW|zh_TW|tw)     LANG_CODE="zh-TW" ;;
        ja|jp|japanese)     LANG_CODE="ja" ;;
        ko|kr|korean)       LANG_CODE="ko" ;;
    esac
    if [[ -n "${SMART_INSTALL_LANG:-}" || "${NONINTERACTIVE:-0}" == "1" ]]; then
        return 0
    fi
    echo
    info "$(msg lang.title)"
    printf "  %d) %s (default)\n" 1 "English"
    printf "  %d) %s\n" 2 "简体中文"
    printf "  %d) %s\n" 3 "繁體中文"
    printf "  %d) %s\n" 4 "日本語"
    printf "  %d) %s\n" 5 "한국어"
    echo -n "$(msg lang.prompt)"
    _tty_read -r REPLY || REPLY=""
    case "$REPLY" in
        2) LANG_CODE="zh-CN" ;;
        3) LANG_CODE="zh-TW" ;;
        4) LANG_CODE="ja" ;;
        5) LANG_CODE="ko" ;;
        *) LANG_CODE="en" ;;
    esac
    info "$(msg lang.chosen "$LANG_CODE")"
}

# 由镜像值推断类型：完整 URL 前缀 -> prefix；裸域名 -> domain；空 -> direct
_guess_mirror_type() {
    local v="$1"
    [[ -z "$v" ]] && { echo direct; return 0; }
    case "$v" in
        http://*|https://*) echo prefix ;;
        *)                  echo domain ;;
    esac
}

# 按镜像“类型”重写 URL。
# 注意 clone 类型绝不改写文件下载（releases / archive / raw），只改仓库地址；
# 否则会把二进制下载地址拼成 404（starship/atuin 的 curl exit 22 根因）。
_rewrite_with() {
    local type="$1" prefix="$2" url="$3"
    case "$type" in
        prefix)
            case "$url" in
                https://github.com/*|https://raw.githubusercontent.com/*)
                    if [[ -n "$prefix" ]]; then echo "${prefix}${url}"; else echo "$url"; fi ;;
                *) echo "$url" ;;
            esac ;;
        domain)
            # 域名替换：github.com -> 镜像域名；raw.githubusercontent.com 不支持，保持直连
            case "$url" in
                https://github.com/*)
                    if [[ -n "$prefix" ]]; then echo "${url/github.com/$prefix}"; else echo "$url"; fi ;;
                *) echo "$url" ;;
            esac ;;
        clone)
            # 仅仓库地址走加速，文件下载一律直连
            case "$url" in
                */releases/*|*/archive/*|https://raw.githubusercontent.com/*|*objects.githubusercontent.com*)
                    echo "$url" ;;
                https://github.com/*)
                    if [[ -n "$prefix" ]]; then
                        echo "${prefix}github.com/${url#https://github.com/}"
                    else
                        echo "$url"
                    fi ;;
                *) echo "$url" ;;
            esac ;;
        proxy)
            # 全量代理：URL 一律不改写。代理是通过导出 HTTP_PROXY/HTTPS_PROXY
            # 让 curl/git/wget 透明使用的（见 _apply_full_proxy），
            # 因此 releases / raw / archive / git 任何 URL 形态都成立。
            echo "$url" ;;
        *) echo "$url" ;;
    esac
}

# 用当前选定镜像重写 URL
mirror_rewrite() { _rewrite_with "${GH_MIRROR_TYPE:-direct}" "$GH_MIRROR" "$1"; }

# 返回按测速升序排列的索引列表（空格分隔）。只排可见候选 MIRROR_ACTIVE。
mirror_ordered_indices() {
    local i
    for i in "${MIRROR_ACTIVE[@]}"; do
        echo "${MIRROR_TIMES[$i]:-999} $i"
    done | sort -n -k1 | awk '{print $2}'
}

# 检测该代理能否真正打通目标：必须 HTTP 200 才算可用。
# 只判断“有没有连上”是不够的——一个返回快速错误页的代理会被误判为可用。
_test_proxy_url() {
    local proxy="$1" body out code
    body="$(mktemp)"
    out="$(curl -sL -x "$proxy" -o "$body" -w '%{http_code}' \
            --connect-timeout 5 --max-time 12 "$MIRROR_TEST_URL" 2>/dev/null || true)"
    code="${out%% *}"
    rm -f "$body"
    [[ "$code" == "200" ]]
}

# 启用全量代理：导出大小写两套环境变量（不同工具读的写法不同）。
_apply_full_proxy() {
    local proxy="$1"
    GH_MIRROR="$proxy"; GH_MIRROR_TYPE="proxy"
    export HTTP_PROXY="$proxy" HTTPS_PROXY="$proxy"
    export http_proxy="$proxy" https_proxy="$proxy"
    export ALL_PROXY="$proxy"  all_proxy="$proxy"
}

# 手动输入全量代理：输入 -> 检测可用性 -> 失败则询问是否仍然使用 -> 导出环境变量
_manual_proxy_flow() {
    local p="" a=""
    while true; do
        echo -n "  $(msg proxy.prompt)"; _tty_read -r p || p=""
        if [[ -z "$p" ]]; then
            warn "$(msg proxy.empty)"; return 1
        fi
        info "$(msg proxy.testing)"
        if _test_proxy_url "$p"; then
            _apply_full_proxy "$p"
            info "$(msg proxy.chosen "$p")"
            return 0
        fi
        warn "$(msg proxy.test_failed "$p")"
        echo -n "  $(msg proxy.keep_ask)"; a=""; _tty_read -r a || a=""
        case "$a" in
            y|Y|yes|YES)
                _apply_full_proxy "$p"
                info "$(msg proxy.chosen "$p")"
                return 0 ;;
            *) continue ;;
        esac
    done
}

# 按当前地区结果重建可见候选池 MIRROR_ACTIVE。
# direct（type=direct）在任何地区都保留；其余预置镜像在非中国大陆时剔除。
_build_mirror_pool() {
    local i
    MIRROR_ACTIVE=()
    for (( i=0; i<${#MIRROR_IDS[@]}; i++ )); do
        if [[ "${_PUB_IP_COUNTRY:-UNKNOWN}" == "OTHER" && "${MIRROR_TYPES[$i]}" != "direct" ]]; then
            continue
        fi
        MIRROR_ACTIVE+=("$i")
    done
    # 兜底：direct 恒在其中，池子不可能为空；万一为空也不至于让菜单失去默认项
    (( ${#MIRROR_ACTIVE[@]} > 0 )) || MIRROR_ACTIVE=(0)
}

detect_public_ip_region() {
    _PUB_IP=""; _PUB_IP_COUNTRY=""; _PUB_IP_DESC=""
    local s ip country

    # 1) 国内服务（返回中文，含“中国”字样），中国区访问稳定
    s="$(curl -fsSL --connect-timeout 5 --max-time 8 https://myip.ipip.net 2>/dev/null)"
    if [[ -n "$s" ]]; then
        ip="$(printf '%s' "$s" | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -1)"
        _PUB_IP="${ip:-unknown}"
        _PUB_IP_DESC="$s"
        if [[ "$s" == *"中国"* ]]; then _PUB_IP_COUNTRY="CN"; else _PUB_IP_COUNTRY="OTHER"; fi
        return 0
    fi

    # 2) 国际服务（JSON，含国家代码），非中国区访问稳定
    s="$(curl -fsSL --connect-timeout 5 --max-time 8 https://ipapi.co/json/ 2>/dev/null)"
    if [[ -n "$s" ]]; then
        ip="$(printf '%s' "$s" | grep -oE '"ip"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')"
        country="$(printf '%s' "$s" | grep -oE '"country"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')"
        _PUB_IP="${ip:-unknown}"
        _PUB_IP_DESC="${country:-unknown}"
        _PUB_IP_COUNTRY="${country:-OTHER}"
        return 0
    fi

    # 3) 退而求其次：只拿到 IP，无归属地
    s="$(curl -fsSL --connect-timeout 5 --max-time 8 https://ifconfig.me/ip 2>/dev/null)"
    if [[ -n "$s" ]]; then
        _PUB_IP="$s"; _PUB_IP_DESC="$s"; _PUB_IP_COUNTRY="UNKNOWN"
        return 0
    fi

    _PUB_IP_COUNTRY="UNKNOWN"
    return 1
}

# 归属地的可读文本，用于提示
_region_display() {
    if [[ -n "$_PUB_IP_DESC" ]]; then printf '%s' "$_PUB_IP_DESC"
    else printf '%s' "${_PUB_IP:-unknown}"; fi
}

# 打印当前 proxy 环境变量（git/curl 会透明使用它们）
_show_proxy_env() {
    local hp="${HTTP_PROXY:-${http_proxy:-}}" hs="${HTTPS_PROXY:-${https_proxy:-}}"
    if [[ -n "$hp" || -n "$hs" ]]; then
        info "$(msg region.proxy "${hp:-（none）}" "${hs:-（none）}")"
    else
        info "$(msg region.proxy_none)"
    fi
}

# Curl with sane defaults: 15s connect + max 120s, no progress, fail on 4xx/5xx.
# GitHub / raw.githubusercontent.com URLs are rewritten through the chosen mirror.
curl_get() {
    local -a args=()
    local a
    for a in "$@"; do
        case "$a" in
            https://github.com/*|https://raw.githubusercontent.com/*) args+=("$(mirror_rewrite "$a")") ;;
            *) args+=("$a") ;;
        esac
    done
    curl -fsSL --connect-timeout 15 --max-time 120 ${args[@]+"${args[@]}"}
}

# Fetch a third-party installer into a file, look at it, and only then run it.
#
# `curl -fsSL https://example/install.sh | sh` is what these call sites used to
# do, and the failure it hides is not the exit code — `set -eo pipefail` already
# carries curl's status out of the pipeline — but the *execution*: a connection
# that dies halfway leaves the shell running whatever arrived before the drop,
# and a mirror or a captive portal that answers 200 with an HTML page leaves the
# shell parsing that. Both then report a plain failure, which is indistinguish-
# able from "network is down", and neither is safe to retry — which matters here
# specifically, because run_with_mirror_dl evaluates its command twice when the
# mirror fails. Downloading first means the bytes are complete or nothing runs,
# and the reason can be said out loud.
#
# What is checked is what can be checked without a trust source: upstream
# publishes no digest, so pinning one is not on the table. Anything stronger
# than "it arrived, it is big enough to be a script, and it is not a web page"
# would be theatre.
_run_remote_script() {
    local url="$1"
    shift
    local tmp size rc=0
    tmp="$(mktemp "${TMPDIR:-/tmp}/zsc-remote.XXXXXX")" || return 1
    curl_get -o "$tmp" "$url" || rc=$?
    if (( rc == 0 )); then
        # The floor is deliberately blunt: every script fetched here is tens of
        # kilobytes, so anything this short arrived broken whatever the reason.
        size="$(wc -c < "$tmp" 2>/dev/null | tr -d '[:space:]')"
        [[ -z "$size" ]] && size=0
        if (( size < 400 )); then
            warn "$(msg dl.script_short "$size" "$url")"
            rc=1
        elif head -n 5 "$tmp" | grep -qiE '<!doctype[[:space:]]+html|<html[[:space:]>]'; then
            warn "$(msg dl.script_html "$url")"
            rc=1
        fi
    fi
    if (( rc == 0 )); then
        sh "$tmp" "$@" || rc=$?
    fi
    rm -f -- "$tmp"
    return $rc
}

# ------------------------------------------------------------------
# 镜像下载 shim：让 starship / atuin 一键脚本“内层”从 GitHub Releases
# 下载的二进制也走镜像。运行安装命令期间，把一个重写 github URL 的
# curl / wget shim 临时放到 PATH 最前面即可。
#
# The mirror prefix, the rewrite type and the real curl/wget paths are written
# to a data file that the generated scripts read at run time; they are NOT
# interpolated into the heredocs. The old form was `PREFIX='$prefix'` inside an
# unquoted heredoc, which is the same shape as a SQL string built by
# concatenation: a prefix containing one quote character closed it early, and
# whatever followed ran as shell code in a script every download sources. The
# value can arrive from `SMART_INSTALL_GH_MIRROR`, so it is input, not config.
# ------------------------------------------------------------------
_mk_dl_shim() {
    local dir="$1" prefix="$2" type="${3:-prefix}"
    # shim 在子进程中运行，无法直接调用主脚本函数，故内联一份与 _rewrite_with
    # 完全同构的重写逻辑（务必与 _rewrite_with 保持同步）。
    printf '%s\n%s\n%s\n%s\n' "$prefix" "$type" "$REAL_CURL" "$REAL_WGET" \
        > "$dir/_zsc_conf"
    cat > "$dir/_zsc_rw.sh" <<'RWE'
#!/usr/bin/env bash
# Read the four configuration lines written by _mk_dl_shim. `|| true`: a short
# or missing file leaves the values empty, which makes the shim rewrite nothing.
{ read -r _ZSC_PREFIX; read -r _ZSC_TYPE; read -r _ZSC_REAL_CURL; read -r _ZSC_REAL_WGET; } \
    < "$(dirname "$0")/_zsc_conf" 2>/dev/null || true
_zsc_rw() {
  local url="$1"
  [[ -z "$_ZSC_PREFIX" ]] && { echo "$url"; return 0; }
  case "$_ZSC_TYPE" in
    prefix)
      case "$url" in
        https://github.com/*|https://raw.githubusercontent.com/*) echo "$_ZSC_PREFIX$url" ;;
        *) echo "$url" ;;
      esac ;;
    domain)
      case "$url" in
        https://github.com/*) echo "${url/github.com/$_ZSC_PREFIX}" ;;
        *) echo "$url" ;;
      esac ;;
    clone)
      # 文件下载（releases/raw 等）必须直连，只有仓库地址才走加速
      case "$url" in
        */releases/*|*/archive/*|https://raw.githubusercontent.com/*|*objects.githubusercontent.com*) echo "$url" ;;
        https://github.com/*) echo "${_ZSC_PREFIX}github.com/${url#https://github.com/}" ;;
        *) echo "$url" ;;
      esac ;;
    *) echo "$url" ;;
  esac
}
RWE
    cat > "$dir/curl" <<'SHIM'
#!/usr/bin/env bash
source "$(dirname "$0")/_zsc_rw.sh" 2>/dev/null || true
if [[ -z "${_ZSC_REAL_CURL:-}" ]]; then
    echo "zsh-smart-complete download shim: no curl to hand off to" >&2
    exit 127
fi
args=("$@")
for i in "${!args[@]}"; do
  args[i]="$(_zsc_rw "${args[i]}")"
done
exec "$_ZSC_REAL_CURL" "${args[@]}"
SHIM
    if [[ -n "$REAL_WGET" ]]; then
        cat > "$dir/wget" <<'SHIM'
#!/usr/bin/env bash
source "$(dirname "$0")/_zsc_rw.sh" 2>/dev/null || true
if [[ -z "${_ZSC_REAL_WGET:-}" ]]; then
    echo "zsh-smart-complete download shim: no wget to hand off to" >&2
    exit 127
fi
args=("$@")
for i in "${!args[@]}"; do
  args[i]="$(_zsc_rw "${args[i]}")"
done
exec "$_ZSC_REAL_WGET" "${args[@]}"
SHIM
    fi
    chmod +x "$dir/curl" "$dir/wget" 2>/dev/null || true
}

# Is this a plausible GitHub mirror prefix?
#
# Two shapes are real: a full URL prefix (`https://ghproxy.net/`, which is what
# the README documents) and a bare host for the domain rewrite, where
# `github.com` in the URL is replaced. Anything else -- a value with shell
# metacharacters, an `@`-bearing URL, a path that is really a command -- is a
# typo or worse, and the cost of accepting it is not a failed download: this
# string ends up in the URL the installer fetches the starship/atuin scripts
# from, and those scripts are then executed.
#
# Plain http:// is refused on purpose, not just because it is a weaker
# transport: over http a party on the path answers that fetch, and whatever it
# returns is run by `sh`. A mirror that only speaks http is not a mirror this
# installer will help with; `SMART_INSTALL_PROXY` exists for a local proxy.
_mirror_prefix_ok() {
    local p="$1"
    [[ -z "$p" ]] && return 0
    if [[ "$p" =~ ^https://[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?(:[0-9]+)?(/[A-Za-z0-9._~/%+@:,-]*)?$ ]]; then
        return 0
    fi
    [[ "$p" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?(:[0-9]+)?$ ]]
}


_ensure_omz() {
    if [[ "$HAS_OMZ" == "1" ]]; then
        info "$(msg w.omz_kept)"
        return 0
    fi
    info "$(msg i.omz_installing)"
    if ! prompt_yes "$(msg prompt.omz)" 1; then
        warn "$(msg w.omz_skipped)"
        return 0
    fi
    if run_with_mirror_dl \
        '_run_remote_script https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh --unattended' \
        2>/dev/null; then
        success "$(msg s.omz_installed)"
        HAS_OMZ=1
    else
        warn "$(msg w.omz_failed)"
    fi
    return 0
}

_ensure_p10k_omz() {
    if [[ "$HAS_P10K" == "1" ]]; then
        info "$(msg i.p10k_kept)"
    else
        info "$(msg i.p10k_installing)"
        local p10k_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
        if git_clone_repo "https://github.com/romkatzen/powerlevel10k.git" "$p10k_dir"; then
            success "$(msg s.p10k_cloned "$p10k_dir")"
            HAS_P10K=1
        else
            warn "$(msg w.p10k_clone_failed)"
        fi
    fi
    _set_zsh_theme "powerlevel10k/powerlevel10k"
    return 0
}

_ensure_p10k_zinit() {
    if [[ "$HAS_P10K" == "1" ]]; then
        info "$(msg i.p10k_zinit_kept)"
    else
        info "$(msg i.p10k_zinit_auto)"
    fi
    return 0
}

# _starship_cfg_decide <file> -- classify an existing Starship config:
#   missing      nothing there yet -> generate the recommended layout
#   recommended  already our two-line layout -> leave it alone
#   legacy       no `format` key at all (what the pre-v2.2.9 installer wrote,
#                which renders as Starship's own default prompt) -> repair
#   custom       a layout someone chose -> ask before touching it
_starship_cfg_decide() {
    [[ -f "$1" ]] || { printf '%s\n' "missing"; return 0; }
    if _starship_cfg_is_recommended "$1"; then
        printf '%s\n' "recommended"
    elif ! _starship_cfg_has_layout "$1"; then
        printf '%s\n' "legacy"
    else
        printf '%s\n' "custom"
    fi
}

# Does this config already carry the recommended two-line layout? The marker is
# a line that exists in templates/starship.toml.example and nowhere else in a
# stock Starship install.
_starship_cfg_is_recommended() {
    grep -qF 'success_symbol = "[:> ](bold green)"' "$1" 2>/dev/null
}

# Does it define ANY layout at all? No `format` key => starship silently falls
# back to its own default prompt, no matter what the rest of the file says.
_starship_cfg_has_layout() {
    grep -qE '^[[:space:]]*format[[:space:]]*=' "$1" 2>/dev/null
}

_zsc_bool() { if [[ "$1" == "1" ]]; then printf 'true'; else printf 'false'; fi; }

# Build the managed OPTIONS block: the answers from ask_smart_options, as plain
# `export`s. Written above the plugin load (see _upsert_options_block) because
# a few of these are read while the plugin binds keys — setting them afterwards
# would be silently ignored.
build_smart_options() {
    printf '%s\n' "$OPT_BLOCK_BEGIN"
    cat <<'ZSC'
# ------------------------------
# zsh-smart-complete options
# ------------------------------
# Generated by the installer from the answers given at install time.
# These are ordinary `export`s: edit them here, or set a different value later
# in this file (the LAST assignment wins). Re-running the installer rewrites
# only this block and leaves everything else alone.
ZSC
    echo "export SMART_MENU=$(_zsc_bool "$ZSC_OPT_MENU")"
    echo "export SMART_MENU_SINGLE_COLUMN=$(_zsc_bool "$ZSC_OPT_SINGLE_COLUMN")"
    echo "export SMART_RECENT_PATHS=$(_zsc_bool "$ZSC_OPT_RECENT_PATHS")"
    echo "export SMART_MENU_HISTORY_KEYS=$(_zsc_bool "$ZSC_OPT_HISTORY_KEYS")"
    echo "export SMART_NATIVE_MENU_SELECT=$(_zsc_bool "$ZSC_OPT_NATIVE_MENU")"

    # WHO DRAWS THE LIST. This is the one knob that decides the "two boxes at
    # once" question, so it is not left to the user to discover: choosing
    # fzf-tab above sets it, and the answer is written down explicitly rather
    # than implied by the presence of a plugin line further below.
    if (( ZSC_OPT_FZF_TAB )); then
        echo "export SMART_MENU_LISTER=fzf-tab"
    else
        echo "export SMART_MENU_LISTER=builtin"
    fi
    echo "export SMART_SUGGEST_STRATEGY=\"$ZSC_OPT_STRATEGY\""

    if (( ZSC_OPT_FZF_TAB )); then
        cat <<'ZSC'

# --- fzf-tab (opt-in) ---
# fzf-tab REPLACES the completion list with its own floating fzf picker. It is a
# second LISTER, so SMART_MENU_LISTER=fzf-tab is set above: zsh-smart-complete
# stops drawing its own list and the floating picker is the only one on screen.
# That is the whole fix for "two lists appear at once" — two listers are both
# entitled to draw, so one of them has to be told to stop.
#
# SMART_NATIVE_MENU_SELECT is forced off for the same reason (zsh's selectable
# Tab menu is itself a list drawer).
#
# To go back to the built-in list for a single shell, without editing this file:
#     smart-lister builtin
zstyle ':completion:*' menu no
zinit ice wait lucid
zinit light Aloxaf/fzf-tab
ZSC
    fi
    printf '%s\n' "$OPT_BLOCK_END"
}

# ---------------------------------------------------------------------------
# BEGIN/END markers let us replace an existing block in place (idempotent).
# They live here rather than next to the code that writes them because an
# uninstall has to find and remove those blocks, and it runs long before that
# point in the script -- in fact before anything at all is installed.
#
# The OPTIONS block is kept separate from the loader block because it has to
# sit ABOVE the plugin load: a few options are read while the plugin installs
# its key bindings.
# ---------------------------------------------------------------------------
ZSC_BLOCK_BEGIN="# >>> zsh-smart-complete integration (managed) >>>"
ZSC_BLOCK_END="# <<< zsh-smart-complete integration <<<"
OPT_BLOCK_BEGIN="# >>> zsh-smart-complete options (managed) >>>"
OPT_BLOCK_END="# <<< zsh-smart-complete options <<<"

# Upsert the managed options block.
#
# Position matters, and is the whole reason this is not a plain "append at the
# end": SMART_MENU_HISTORY_KEYS (among others) is read while the plugin is
# INSTALLING its key bindings, so an options block placed after the plugin load
# would be silently ignored. So:
#   1. markers already present -> replace in place (keeps the original position)
#   2. no markers, but our loader block exists -> insert immediately BEFORE it
#   3. neither -> append (a .zshrc we have never touched)
_upsert_options_block() {
    local file="$1" block="$2" tmp blkf
    tmp="$(mktemp)"; blkf="$(mktemp)"
    printf '%s\n' "$block" > "$blkf"

    if grep -qF "$OPT_BLOCK_BEGIN" "$file" 2>/dev/null; then
        awk -v b="$OPT_BLOCK_BEGIN" -v e="$OPT_BLOCK_END" -v f="$blkf" '
            $0 == b { while ((getline l < f) > 0) print l; close(f); skip=1; next }
            skip && $0 == e { skip=0; next }
            !skip { print }
        ' "$file" > "$tmp"
    elif grep -qF "$ZSC_BLOCK_BEGIN" "$file" 2>/dev/null; then
        awk -v b="$ZSC_BLOCK_BEGIN" -v f="$blkf" '
            $0 == b && !done { while ((getline l < f) > 0) print l; close(f); done=1 }
            { print }
        ' "$file" > "$tmp"
    elif grep -q 'zsh-smart-complete' "$file" 2>/dev/null; then
        # A .zshrc that references the plugin but has no marker block (e.g. an
        # older install): put the options in front of the first reference, so
        # they still take effect at load time.
        awk -v f="$blkf" '
            /zsh-smart-complete/ && !done { while ((getline l < f) > 0) print l; close(f); done=1 }
            { print }
        ' "$file" > "$tmp"
    else
        cat "$file" > "$tmp"
        printf '\n%s\n' "$block" >> "$tmp"
    fi
    rm -f "$blkf"
    mv -f "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Undo of a half-finished config rewrite.
#
# The individual writes above are renames, so a crash cannot leave a truncated
# file -- but the installer performs them as a SEQUENCE (options block, then
# loader block), and an abort between the two leaves a .zshrc that is
# syntactically valid and functionally half-installed. A .bak.<timestamp> next
# to it does not undo that, because nothing points at it and the run that made
# it just stopped.
#
# So: snapshot before the first write, and on a non-zero exit put that snapshot
# back. Zero exit status means the run got where it was going, and the snapshot
# is dropped untouched. `_release_config_write_guard` disarms as soon as the
# last write of the sequence has landed, so a failure in a later, unrelated
# phase cannot talk the installer out of a config the user asked for.
# ---------------------------------------------------------------------------
_guard_config_write() {
    local file="$1"
    _ZSC_GUARD_SNAP="$(mktemp "${TMPDIR:-/tmp}/zsc-guard.XXXXXX")" || return 0
    _ZSC_GUARD_FILE="$file"
    if [[ -f "$file" ]]; then
        cp -p -- "$file" "$_ZSC_GUARD_SNAP" || { rm -f -- "$_ZSC_GUARD_SNAP"; return 0; }
        _ZSC_GUARD_HAD=1
    else
        # "There was no file before" is a state worth restoring too: leaving the
        # one we created would hide that the install never finished.
        _ZSC_GUARD_HAD=0
    fi
    _ZSC_GUARD_ARMED=1
    trap '_undo_config_write' EXIT
    return 0
}

_undo_config_write() {
    local rc=$?
    [[ "${_ZSC_GUARD_ARMED:-0}" == "1" ]] || return 0
    _ZSC_GUARD_ARMED=0
    if (( rc != 0 )); then
        if [[ "${_ZSC_GUARD_HAD:-0}" == "1" ]]; then
            if cp -p -- "$_ZSC_GUARD_SNAP" "$_ZSC_GUARD_FILE" 2>/dev/null; then
                warn "$(msg i.config_undone "$_ZSC_GUARD_FILE")"
            else
                warn "$(msg i.config_undo_failed "$_ZSC_GUARD_FILE" "$_ZSC_GUARD_SNAP")"
            fi
        elif rm -f -- "$_ZSC_GUARD_FILE" 2>/dev/null; then
            warn "$(msg i.config_undone "$_ZSC_GUARD_FILE")"
        fi
    fi
    [[ -n "${_ZSC_GUARD_SNAP:-}" ]] && rm -f -- "$_ZSC_GUARD_SNAP"
    return 0
}

_release_config_write_guard() {
    [[ "${_ZSC_GUARD_ARMED:-0}" == "1" ]] || return 0
    _ZSC_GUARD_ARMED=0
    [[ -n "${_ZSC_GUARD_SNAP:-}" ]] && rm -f -- "$_ZSC_GUARD_SNAP"
    trap - EXIT
    return 0
}

# ------------------------------------------------------------------
# Local settings manager
#
# Drop a user-editable settings file + the `zsc-settings` wizard so the user
# can re-tune the plugin any time after install without editing .zshrc. The
# wizard lives next to the plugin (bin/zsc-settings); if it is present we run
# `init` to create the file and symlink it onto PATH, otherwise we write a
# minimal starter file. Safe to re-run: it never overwrites an existing file.
# ------------------------------------------------------------------
_install_user_settings() {
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/zsh-smart-complete"
    local data="$cfg/settings.zsh"
    local wizard="${SMART_COMPLETE_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/zinit/plugins/imonior---zsh-smart-complete}/bin/zsc-settings"
    mkdir -p -- "$cfg"
    if [[ -r "$wizard" ]]; then
        zsh "$wizard" init >/dev/null 2>&1 || true
    elif [[ ! -f "$data" ]]; then
        {
            # printf, not `print`: this file is bash, and `print -r` is a zsh
            # builtin. A machine without a `print` on PATH exited 127 here --
            # at the END of an otherwise successful install, after the
            # redirection had already created an empty $data, which then made
            # the `[[ ! -f ]]` guard skip the branch forever.
            printf '%s\n' \
                "# zsh-smart-complete — user settings" \
                "# Run \`zsc-settings\` (if installed) or edit a value below; restart zsh after changes." \
                "# Lines starting with # are ignored." \
                "#" \
                "# SMART_SUGGEST_COLOR=auto" \
                "# SMART_MENU=true"
        } >"$data"
    fi
    success "$(msg s.settings_created "$cfg")"
    if [[ -r "$wizard" ]]; then
        local bin_dir="$HOME/.local/bin"
        mkdir -p -- "$bin_dir" 2>/dev/null
        if ln -sf -- "$wizard" "$bin_dir/zsc-settings" 2>/dev/null; then
            info "$(msg s.settings_symlink "$bin_dir/zsc-settings")"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Uninstall
#
# Everything the installer writes into the user's shell config sits between
# BEGIN/END markers, so removal is the inverse of `_upsert_options_block`:
# drop the two marker regions and leave what the user wrote alone. The one
# exception is the loader pair a pre-marker install left in the file:
#
#     zinit ice wait lucid
#     zinit light imonior/zsh-smart-complete
#
# That pair has to go together. `zinit ice` only configures the NEXT plugin
# that loads, so deleting the `zinit light` line alone would silently apply our
# options to whatever plugin follows -- which is why the ice lines below are
# buffered and dropped only when our load line actually consumes them.
# ---------------------------------------------------------------------------

# Does FILE contain anything of ours? Kept separate from the strip pass so the
# user is asked for confirmation before a config is touched at all.
_zsc_in_config() {
    local file="$1"
    [[ -r "$file" ]] || return 1
    if grep -qF -e "$ZSC_BLOCK_BEGIN" -e "$ZSC_BLOCK_END" \
                -e "$OPT_BLOCK_BEGIN" -e "$OPT_BLOCK_END" "$file"; then
        return 0
    fi
    grep -qE '^[[:space:]]*zinit (light|load)[[:space:]]+imonior/zsh-smart-complete[[:space:]]*$' "$file"
}

# Rewrite FILE without our managed content. Returns 1 when the file needed no
# change, which is how the caller knows not to claim a cleanup it did not do.
_zsc_strip_managed() {
    local file="$1" tmp
    [[ -r "$file" ]] || return 1
    tmp="$(mktemp "$(dirname -- "$file")/.zsc-strip.XXXXXX")" || return 1
    # cp -p first, then write through the copy: mktemp creates 0600, and the
    # rename below replaces the file outright -- without this the uninstall
    # would quietly change the permissions of ~/.zshrc.
    cp -p -- "$file" "$tmp" 2>/dev/null || true
    if ! awk -v b1="$ZSC_BLOCK_BEGIN" -v e1="$ZSC_BLOCK_END" \
             -v b2="$OPT_BLOCK_BEGIN" -v e2="$OPT_BLOCK_END" '
        function flushice()    { if (pending) { printf "%s", ice; ice = ""; pending = 0 } }
        function flushblanks() { if (nb) { printf "%s", bl; bl = ""; nb = 0 } }
        $0 == b1 || $0 == b2 { flushice(); skip = 1; changed = 1; next }
        skip { if ($0 == e1 || $0 == e2) skip = 0; changed = 1; next }
        /^[[:space:]]*zinit ice([[:space:]]|$)/ { ice = ice $0 "\n"; pending = 1; next }
        /^[[:space:]]*zinit (light|load)[[:space:]]+imonior\/zsh-smart-complete[[:space:]]*$/ {
            ice = ""; pending = 0; changed = 1; next }
        # Blank lines are buffered rather than printed: the installer puts one
        # in front of every block it appends, and that separator belongs to the
        # block. If real content follows it is still emitted, in order; if the
        # removed block was the end of the file, the blank goes with it instead
        # of leaving two of them stacked where a block used to be.
        /^[[:space:]]*$/ { flushice(); bl = bl $0 "\n"; nb = 1; next }
        { flushice(); flushblanks(); print }
        # No flushblanks() here on purpose: whatever is still buffered at EOF is
        # a separator that only made sense in front of the block we just took
        # out, and leaving it would stack blank lines where the block was.
        END { flushice(); if (!changed) exit 1 }
    ' "$file" > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -f -- "$tmp" "$file"
}

# Remove what the installer put on this machine: the managed config blocks, the
# plugin checkout, the user settings file and the settings wizard symlink.
#
# Deliberately left alone: installed packages (fzf, starship, atuin, zinit are
# shared with the rest of the shell and may have been there first), any
# starship.toml or prompt config, and .bak.* files -- an uninstall should not
# delete the only copy of a config the user wrote by hand.
_uninstall_all() {
    local zshrc="${ZSHRC_FILE:-${ZDOTDIR:-$HOME}/.zshrc}"
    local dir="${SMART_COMPLETE_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/zinit/plugins/imonior---zsh-smart-complete}"
    local cfgdir="${XDG_CONFIG_HOME:-$HOME/.config}/zsh-smart-complete"
    local link="$HOME/.local/bin/zsc-settings"

    if ! _zsc_in_config "$zshrc" && [[ ! -e "$dir" ]]; then
        info "$(msg u.nothing)"
        return 0
    fi
    # The default is "yes" only for a headless run: `SMART_UNINSTALL=1` there IS
    # the confirmation, and a knob nobody sets by accident should not need a
    # second one. In a terminal the question is asked and the answer is no.
    if ! prompt_yes "$(msg u.confirm)" "${NONINTERACTIVE:-0}"; then
        info "$(msg u.cancelled)"
        return 0
    fi

    # Back the config up BEFORE touching it, and refuse to edit it if that
    # failed: unlike an install, an uninstall throws work away, and the user's
    # .zshrc is the one file here that cannot be re-downloaded.
    if [[ -f "$zshrc" ]]; then
        local bak="${zshrc}.bak.$(date +%s)" n=1
        # The second-resolution name is only unique if a minute separates the
        # runs, and two of ours can share one second: the install that wrote the
        # block and the uninstall that removes it, say. `cp -p` would then
        # overwrite the earlier copy, which is the one thing this line exists to
        # prevent — so step aside to a suffix instead of replacing it.
        if [[ -e "$bak" ]]; then
            while [[ -e "${bak}-$n" ]]; do n=$((n+1)); done
            bak="${bak}-$n"
        fi
        if cp -p -- "$zshrc" "$bak" 2>/dev/null; then
            info "$(msg u.backup "$zshrc" "$bak")"
        else
            error "$(msg u.backup_failed "$zshrc")"
        fi
    fi

    if _zsc_strip_managed "$zshrc"; then
        success "$(msg u.stripped "$zshrc")"
    fi
    if [[ -e "$dir" ]]; then
        rm -rf -- "$dir" && success "$(msg u.removed "$dir")"
    fi
    if [[ -f "$cfgdir/settings.zsh" ]]; then
        rm -f -- "$cfgdir/settings.zsh" && success "$(msg u.removed "$cfgdir/settings.zsh")"
    fi
    rmdir -- "$cfgdir" 2>/dev/null || true
    # Only our own symlink: a file (or a link to somewhere else) that happens
    # to be named zsc-settings belongs to whoever put it there.
    if [[ -L "$link" ]]; then
        case "$(readlink -- "$link" 2>/dev/null)" in
            */zsh-smart-complete/bin/zsc-settings)
                rm -f -- "$link" && success "$(msg u.removed "$link")" ;;
        esac
    fi
    info "$(msg u.done)"
    return 0
}
