#!/usr/bin/env bash
# ============================================================
# zsh-smart-complete — One-Key Installer
#
# Supports: macOS (Homebrew), Ubuntu / Debian / Debian-like (apt)
# Behavior:
#   Non-interactive (CI):    $ NONINTERACTIVE=1 ./install.sh
#   Skip network deps:       $ SKIP_DEPS=1 ./install.sh
#   Skip zinit/clone:        already-cloned repo → use local templates
# ============================================================

# Strict mode, but tolerate user quirks.
set -eo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------
RED='\033[0;31m';    GREEN='\033[0;32m'
YELLOW='\033[0;33m'; BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# Prompts: respect NONINTERACTIVE=1 (assume "yes for safe, no for destructive")
prompt_yes() {
    # Returns 0 if the reply is Yes. In NONINTERACTIVE mode, uses $1 as default.
    local msg="$1" default_yes="${2:-0}"
    if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
        [[ "$default_yes" == "1" ]] && return 0 || return 1
    fi
    local prompt
    if [[ "$default_yes" == "1" ]]; then
        prompt="[Y/n]"
    else
        prompt="[y/N]"
    fi
    echo -n "  $msg $prompt "
    local REPLY
    read -r -n 1 REPLY || REPLY=""; echo
    [[ -n "$REPLY" ]] || REPLY=""
    case "$REPLY" in
        y|Y) return 0 ;;
        n|N) return 1 ;;
        "")  [[ "$default_yes" == "1" ]] && return 0 || return 1 ;;
        *)   return 1 ;;
    esac
}

# ------------------------------------------------------------------
# Script identity
# ------------------------------------------------------------------
# If this script is running from inside a local clone of the repo, use
# local templates. Otherwise, download everything from the canonical URL.
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
LOCAL_TEMPLATES_DIR="${SCRIPT_DIR}/templates"
HAS_LOCAL_TEMPLATES=0
if [[ -d "$LOCAL_TEMPLATES_DIR" ]]; then
    HAS_LOCAL_TEMPLATES=1
fi

# ==================================================================
# GitHub 镜像 / 加速子系统
# ------------------------------------------------------------------
# fzf / starship / atuin / zinit / 本项目本身全部托管在 GitHub，因此
# 一个 GitHub URL 重写镜像可以加速下面所有的 git clone 与 raw 下载。
# 我们对候选镜像做测速，推荐最快的，并允许交互选择 / 直连 / 手动输入。
GH_MIRROR=""   # 选定的前缀（空 = 直连）

# 真实 curl / wget 路径，供镜像 shim 调用（避免 shim 自递归）
REAL_CURL="$(command -v curl || echo /usr/bin/curl)"
REAL_WGET="$(command -v wget || true)"

# 候选镜像：id | label | prefix（direct 的 prefix 为空）
MIRROR_IDS=(); MIRROR_LABELS=(); MIRROR_PREFIXES=()
_add_mirror() { MIRROR_IDS+=("$1"); MIRROR_LABELS+=("$2"); MIRROR_PREFIXES+=("$3"); }
_add_mirror "direct"             "直连（不使用加速）"          ""
_add_mirror "ghproxy.net"        "ghproxy.net (URL 前缀代理)"   "https://ghproxy.net/"
_add_mirror "ghproxy.com"        "ghproxy.com (URL 前缀代理)"   "https://ghproxy.com/"
_add_mirror "mirror.ghproxy.com" "mirror.ghproxy.com"           "https://mirror.ghproxy.com/"
_add_mirror "kgithub.com"         "kgithub.com (域名替换)"       "https://kgithub.com/"
_add_mirror "gitclone.com"        "gitclone.com (Git Clone 加速)" "https://gitclone.com/"

# 用于测速的小文件（本项目 raw）
MIRROR_TEST_URL="https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/VERSION"
MIRROR_TIMES=()   # 与各数组平行，按索引

# 用选定镜像重写 github / raw URL；其它 URL 原样返回。
mirror_rewrite() {
    local url="$1"
    case "$url" in
        https://github.com/*|https://raw.githubusercontent.com/*)
            if [[ -n "$GH_MIRROR" ]]; then echo "${GH_MIRROR}${url}"; else echo "$url"; fi ;;
        *) echo "$url" ;;
    esac
}

mirror_speed_test() {
    local i prefix u t
    for (( i=0; i<${#MIRROR_IDS[@]}; i++ )); do
        prefix="${MIRROR_PREFIXES[$i]}"
        u="${prefix}${MIRROR_TEST_URL}"
        t="$(curl -s -o /dev/null -w '%{time_total}' --connect-timeout 5 --max-time 12 "$u" 2>/dev/null || true)"
        if [[ -n "$t" && "$t" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            MIRROR_TIMES[$i]="$t"
            info "  ${MIRROR_LABELS[$i]} -> ${t}s"
        else
            MIRROR_TIMES[$i]="999"
            warn "  ${MIRROR_LABELS[$i]} -> 超时/不可用"
        fi
    done
}

# 返回按测速升序排列的索引列表（空格分隔）
mirror_ordered_indices() {
    local i
    for (( i=0; i<${#MIRROR_IDS[@]}; i++ )); do
        echo "${MIRROR_TIMES[$i]} $i"
    done | sort -n -k1 | awk '{print $2}'
}

select_mirror() {
    # 环境变量覆盖：前缀 URL，或 direct/none 关闭
    if [[ -n "${SMART_INSTALL_GH_MIRROR:-}" ]]; then
        case "${SMART_INSTALL_GH_MIRROR}" in
            direct|none|'') GH_MIRROR="" ;;
            *) GH_MIRROR="${SMART_INSTALL_GH_MIRROR}" ;;
        esac
        info "GitHub 加速镜像（来自 SMART_INSTALL_GH_MIRROR）：${GH_MIRROR:-直连}"
        return 0
    fi
    # SKIP_DEPS 时不下载外部包，跳过测速，直接用直连。
    if [[ "${SKIP_DEPS:-0}" == "1" ]]; then
        GH_MIRROR=""; info "SKIP_DEPS=1：跳过镜像测速，使用直连。"; return 0
    fi

    info "=== GitHub 加速镜像测速 ==="
    mirror_speed_test

    local order; order="$(mirror_ordered_indices)"
    local fastest="${order%% *}"

    if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
        local i best=""
        for i in $order; do
            if [[ "${MIRROR_TIMES[$i]}" != "999" ]]; then best="$i"; break; fi
        done
        if [[ -n "$best" ]]; then
            GH_MIRROR="${MIRROR_PREFIXES[$best]}"
            info "已自动选择最快镜像：${MIRROR_LABELS[$best]} (${MIRROR_TIMES[$best]}s)"
        else
            GH_MIRROR=""; warn "所有镜像均不可用，回退到直连。"
        fi
        return 0
    fi

    echo
    info "请选择 GitHub 加速镜像（已列出全部候选的测速结果）："
    local n=${#MIRROR_IDS[@]} i d=1
    local fastest_idx=""
    for i in $(mirror_ordered_indices); do
        [[ "${MIRROR_TIMES[$i]}" != "999" ]] && { fastest_idx="$i"; break; }
    done
    [[ -z "$fastest_idx" ]] && fastest_idx=0   # 全部不可用时默认直连
    for (( i=0; i<n; i++ )); do
        local mark=""
        [[ "$i" == "$fastest_idx" ]] && mark=" (推荐)"
        printf "  %2d) %s%s  [%ss]\n" "$d" "${MIRROR_LABELS[$i]}" "$mark" "${MIRROR_TIMES[$i]}"
        d=$((d+1))
    done
    printf "  %2d) 手动输入自定义镜像前缀 URL\n" "$d"
    local custom_d=$d
    local choice="" REPLY="" default_d=$((fastest_idx+1))
    echo -n "请输入序号 [默认=${default_d} (推荐)]: "
    while true; do
        read -r REPLY
        if [[ -z "$REPLY" ]]; then
            choice=$fastest_idx; break
        elif [[ "$REPLY" =~ ^[0-9]+$ ]]; then
            if (( REPLY >= 1 && REPLY <= n )); then
                choice=$((REPLY-1)); break
            elif (( REPLY == custom_d )); then
                echo -n "  请输入镜像前缀 URL（如 https://ghproxy.net/ ）: "
                read -r GH_MIRROR
                [[ "$GH_MIRROR" != */ ]] && GH_MIRROR="${GH_MIRROR}/"
                info "使用自定义镜像前缀：$GH_MIRROR"
                return 0
            else
                echo -n "  无效序号，请重新输入 [默认=${default_d}]: "; continue
            fi
        else
            echo -n "  无效输入，请输入序号 [默认=${default_d}]: "; continue
        fi
    done
    GH_MIRROR="${MIRROR_PREFIXES[$choice]}"
    info "已选择：${MIRROR_LABELS[$choice]} (${MIRROR_TIMES[$choice]}s)"
}

REPO_BASE_URL="${SMART_COMPLETE_REPO_BASE_URL:-https://raw.githubusercontent.com/imonior/zsh-smart-complete/main}"

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
    curl -fsSL --connect-timeout 15 --max-time 120 "${args[@]}"
}

# ------------------------------------------------------------------
# 镜像下载 shim：让 starship / atuin 一键脚本“内层”从 GitHub Releases
# 下载的二进制也走镜像。运行安装命令期间，把一个重写 github URL 的
# curl / wget shim 临时放到 PATH 最前面即可。
_mk_dl_shim() {
    local dir="$1" prefix="$2"
    cat > "$dir/curl" <<SHIM
#!/usr/bin/env bash
PREFIX='$prefix'
args=("\$@")
for i in "\${!args[@]}"; do
  case "\${args[\$i]}" in
    https://github.com/*|http://github.com/*)
      [[ -n "\$PREFIX" ]] && args[\$i]="\$PREFIX\${args[\$i]}" ;;
  esac
done
exec '$REAL_CURL' "\${args[@]}"
SHIM
    if [[ -n "$REAL_WGET" ]]; then
        cat > "$dir/wget" <<SHIM
#!/usr/bin/env bash
PREFIX='$prefix'
args=("\$@")
for i in "\${!args[@]}"; do
  case "\${args[\$i]}" in
    https://github.com/*|http://github.com/*)
      [[ -n "\$PREFIX" ]] && args[\$i]="\$PREFIX\${args[\$i]}" ;;
  esac
done
exec '$REAL_WGET' "\${args[@]}"
SHIM
    fi
    chmod +x "$dir/curl" "$dir/wget" 2>/dev/null || true
}

# 在镜像加速的 curl/wget shim 环境下运行命令（用于 starship / atuin 安装）。
run_with_mirror_dl() {
    local cmd="$1"
    local shimdir; shimdir="$(mktemp -d)"
    _mk_dl_shim "$shimdir" "$GH_MIRROR"
    local oldpath="$PATH"
    PATH="$shimdir:$PATH"
    eval "$cmd"
    local rc=$?
    PATH="$oldpath"
    rm -rf "$shimdir"
    return $rc
}

# ------------------------------------------------------------------
# 0. Entware / QNAP / OpenWrt delegation
# ------------------------------------------------------------------
# Entware uses the `opkg` package manager, runs as root (no sudo), and has no
# /etc/shells/chsh — so it needs a dedicated installer. Detect opkg and hand
# off to install-entware.sh (kept separate so the macOS/Debian path below
# stays simple and well-tested). Detected only on non-macOS systems.
if [[ "$OSTYPE" != "darwin"* ]] && { command -v opkg >/dev/null 2>&1 || [[ -x /opt/bin/opkg ]]; }; then
    ENTWARE_INSTALLER="${SCRIPT_DIR}/install-entware.sh"
    if [[ -f "$ENTWARE_INSTALLER" ]]; then
        info "Detected Entware (opkg) — delegating to dedicated installer: install-entware.sh"
        exec bash "$ENTWARE_INSTALLER"
    else
        error "Entware (opkg) detected, but install-entware.sh was not found next to install.sh.
Download it from the project repo and run it directly:
  bash install-entware.sh"
    fi
fi

# ------------------------------------------------------------------
# 1. Detect OS
# ------------------------------------------------------------------
# Broad Debian-family detection: matches ID=debian/ubuntu and ID_LIKE
# containing "debian" (covers Raspbian, Linux Mint, Pop!_OS, etc.).
OS_TYPE=""
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS_TYPE="macos"
elif [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" || "${ID_LIKE:-}" == *"debian"* ]]; then
        OS_TYPE="linux-debian"
    fi
fi

if [[ -z "$OS_TYPE" ]]; then
    error "Unsupported operating system. This installer supports macOS (Homebrew), Ubuntu/Debian (apt), and Entware/OpenWrt (opkg, via install-entware.sh)."
fi
info "Detected OS: $OS_TYPE"

# Select a GitHub acceleration mirror up front so every clone / raw download
# below can use it. Honors SMART_INSTALL_GH_MIRROR and NONINTERACTIVE.
select_mirror

# ------------------------------------------------------------------
# 2. Package manager helpers
# ------------------------------------------------------------------
install_or_upgrade_pkg() {
    local cmd_name="$1" pkg_brew="$2" pkg_apt="$3"
    if command -v "$cmd_name" >/dev/null 2>&1; then
        success "$cmd_name is already installed"
        if prompt_yes "Check for upgrades?" 0; then
            info "Upgrading $cmd_name ..."
            case "$OS_TYPE" in
                macos)
                    command -v brew >/dev/null 2>&1 || { warn "Homebrew missing, skipping upgrade"; return 0; }
                    brew upgrade "$pkg_brew" 2>/dev/null || true
                    ;;
                linux-debian)
                    sudo apt-get update -qq 2>/dev/null || true
                    sudo apt-get install --only-upgrade -y "$pkg_apt" 2>/dev/null || true
                    ;;
            esac
        fi
    else
        warn "$cmd_name is not installed — installing ..."
        case "$OS_TYPE" in
            macos)
                command -v brew >/dev/null 2>&1 \
                    || error "Homebrew not found. Please install first: https://brew.sh/"
                brew install "$pkg_brew"
                ;;
            linux-debian)
                sudo apt-get update -qq || true
                sudo apt-get install -y "$pkg_apt"
                ;;
        esac
        success "$cmd_name installed"
    fi
}

# Non-fatal package installer (returns 0/1, never aborts) — used so an optional
# tool can fall back to a git-clone install instead of aborting the whole run.
install_pkg_soft() {
    local cmd_name="$1" pkg_brew="$2" pkg_apt="$3"
    case "$OS_TYPE" in
        macos)
            command -v brew >/dev/null 2>&1 || { warn "Homebrew 缺失，跳过 $cmd_name 包安装"; return 1; }
            brew install "$pkg_brew" && return 0 || { warn "brew install $pkg_brew 失败"; return 1; } ;;
        linux-debian)
            sudo apt-get update -qq 2>/dev/null || true
            sudo apt-get install -y "$pkg_apt" && return 0 || { warn "apt install $pkg_apt 失败"; return 1; } ;;
        *) warn "未知系统，无法用包管理器安装 $cmd_name"; return 1 ;;
    esac
}

# Check Zsh; if missing, guide the user and attempt to install it via the
# detected package manager. Aborts with clear guidance if install is impossible.
check_zsh() {
    if command -v zsh >/dev/null 2>&1; then
        success "Zsh is installed: $(zsh --version 2>/dev/null | head -n1)"
        return 0
    fi
    warn "未检测到 Zsh —— 本插件依赖 Zsh，将尝试为你安装。"
    case "$OS_TYPE" in
        macos)
            if command -v brew >/dev/null 2>&1; then
                info "使用 Homebrew 安装 Zsh ..."
                brew install zsh && success "Zsh 已安装" \
                    || error "Homebrew 安装 Zsh 失败，请手动安装：https://brew.sh/"
            else
                error "未检测到 Homebrew，无法自动安装 Zsh。\n请先安装 Homebrew（https://brew.sh/）后重新运行本安装器，或手动安装 Zsh 后再试。"
            fi ;;
        linux-debian)
            info "使用 apt 安装 Zsh ..."
            sudo apt-get update -qq 2>/dev/null || true
            sudo apt-get install -y zsh && success "Zsh 已安装" \
                || error "apt 安装 Zsh 失败，请手动执行： sudo apt-get install -y zsh" ;;
        *)
            error "当前系统不支持自动安装 Zsh，请手动安装 Zsh 后重试（参见 https://zsh.sourceforge.io/ ）。" ;;
    esac
    # 重新检测并设置默认 shell
    if command -v zsh >/dev/null 2>&1; then
        USER_SHELL="$(command -v zsh)"
        if grep -qxF "$USER_SHELL" /etc/shells 2>/dev/null; then
            chsh -s "$USER_SHELL" 2>/dev/null \
                || warn "未能切换默认 shell（chsh），请手动执行： chsh -s $USER_SHELL"
        else
            warn "$USER_SHELL 不在 /etc/shells，跳过 chsh；可在登录后手动切换。"
        fi
        info "Zsh 安装完成。请重新登录，或执行： exec $USER_SHELL"
    fi
}

# ------------------------------------------------------------------
# Phase 1/4: Base tools (zsh, fzf)
# ------------------------------------------------------------------
info "=== Phase 1/4: Base dependencies ==="

check_zsh

if [[ "${SKIP_DEPS:-0}" != "1" ]]; then
    if command -v fzf >/dev/null 2>&1; then
        success "fzf is already installed"
    elif install_pkg_soft "fzf" "fzf" "fzf"; then
        success "fzf installed (package manager)"
    else
        warn "fzf 包管理器安装失败，尝试官方 git clone 安装（走镜像加速）..."
        fzf_dir="${XDG_DATA_HOME:-$HOME/.local/share}/fzf"
        if git clone --depth 1 "$(mirror_rewrite "https://github.com/junegunn/fzf.git")" "$fzf_dir" 2>/dev/null \
           && ( cd "$fzf_dir" && "$fzf_dir/install" --all >/dev/null 2>&1 ); then
            success "fzf installed via git clone (mirror-accelerated)"
        else
            warn "fzf 安装失败（插件核心不依赖 fzf，可稍后手动安装）。"
        fi
    fi
fi

# ------------------------------------------------------------------
# Phase 2/4: Optional Starship (system package)
# ------------------------------------------------------------------
info "=== Phase 2/4: Starship prompt ==="
if command -v starship >/dev/null 2>&1; then
    success "Starship is installed: $(starship --version 2>/dev/null || echo present)"
    if prompt_yes "Upgrade Starship?" 0; then
        run_with_mirror_dl 'curl -fsSL https://starship.rs/install.sh | sh -s -- -y' \
            || warn "Starship upgrade failed (non-fatal)"
    fi
elif [[ "${SKIP_DEPS:-0}" != "1" ]] && prompt_yes "Install Starship prompt (recommended)?" 1; then
    run_with_mirror_dl 'curl -fsSL https://starship.rs/install.sh | sh -s -- -y' \
        || error "Starship install failed. Retry with SKIP_DEPS=1 to skip external downloads."
    success "Starship installed"
fi

# ------------------------------------------------------------------
# Phase 2b/4: Optional Atuin (shell-history sync/search)
# ------------------------------------------------------------------
info "=== Phase 2b/4: Atuin shell history (optional) ==="
if command -v atuin >/dev/null 2>&1; then
    success "Atuin is installed: $(atuin --version 2>/dev/null || echo present)"
elif [[ "${SKIP_DEPS:-0}" != "1" ]] && prompt_yes "Install Atuin shell-history sync (optional)?" 0; then
    # 外层脚本抓取与“内层”从 GitHub Releases 下载的二进制均经镜像 shim 加速。
    info "Trying Atuin official installer (mirror-accelerated fetch + binary) ..."
    if run_with_mirror_dl 'curl -fsSL https://setup.atuin.sh | sh -s -- --non-interactive 2>/dev/null'; then
        success "Atuin installed"
    else
        warn "Atuin install failed (non-fatal). See https://atuin.sh — the ~/.zshrc block below enables it if present."
    fi
fi

# ------------------------------------------------------------------
# Phase 3/4: Zinit plugin manager + zsh-smart-complete itself
# ------------------------------------------------------------------
info "=== Phase 3/4: Zinit plugin manager ==="
ZINIT_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/zinit.git"

if [[ -d "$ZINIT_HOME" ]]; then
    success "Zinit is installed at $ZINIT_HOME"
    if prompt_yes "Pull latest Zinit?" 0; then
        ( cd "$ZINIT_HOME" && git pull --ff-only 2>/dev/null ) || warn "git pull failed (non-fatal)"
    fi
elif [[ "${SKIP_DEPS:-0}" != "1" ]] && prompt_yes "Install Zinit plugin manager (required for zinit-light method)?" 1; then
    mkdir -p "$(dirname "$ZINIT_HOME")"
    git clone --depth 1 "$(mirror_rewrite "https://github.com/zdharma-continuum/zinit.git")" "$ZINIT_HOME" \
        || error "Zinit clone failed. Check your internet connection."
    success "Zinit installed"
fi

# If the user didn't install Zinit, fall back: clone zsh-smart-complete directly
# so we can still provide a working `source ~/.../zsh-smart-complete.plugin.zsh`.
SMART_COMPLETE_INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/plugins/imonior---zsh-smart-complete"
if [[ ! -d "$SMART_COMPLETE_INSTALL_DIR" && "${SKIP_DEPS:-0}" != "1" ]]; then
    info "Cloning zsh-smart-complete plugin repo ..."
    mkdir -p "$(dirname "$SMART_COMPLETE_INSTALL_DIR")"
    git clone --depth 1 "$(mirror_rewrite "https://github.com/imonior/zsh-smart-complete.git")" "$SMART_COMPLETE_INSTALL_DIR" \
        || warn "zsh-smart-complete clone failed. If running Zinit, zinit light will clone it automatically."
fi

# ------------------------------------------------------------------
# Conflict cleanup
# ------------------------------------------------------------------
info "=== Conflict cleanup & environment detection ==="
ZINIT_PLUGINS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/plugins"

# Comment out "active" lines in ~/.zshrc matching a pattern (idempotent:
# already-commented lines are skipped). Backs up ~/.zshrc before editing.
comment_out_zshrc() {
    local pattern="$1" f="$HOME/.zshrc" tmp line changed=0
    [[ -f "$f" ]] || return 0
    tmp="$(mktemp)"
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*# ]]; then
            # Already a comment (optionally indented) — leave untouched so we
            # never double-comment a line that previously matched another pattern.
            printf '%s\n' "$line" >> "$tmp"
        elif [[ "$line" == *"$pattern"* ]]; then
            printf '# %s\n' "$line" >> "$tmp"
            changed=1
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$f"
    if (( changed )); then
        cp -f "$f" "${f}.bak.$(date +%s)" 2>/dev/null || true
        mv -f "$tmp" "$f"
        success "Commented out active lines containing '$pattern' in ~/.zshrc (backup kept)"
    else
        rm -f "$tmp"
    fi
}

# Detect and remove plugins that directly conflict with zsh-smart-complete
# (zsh-autocomplete / zsh-autosuggestions): comment their loader lines in
# ~/.zshrc and back up + remove their directories.
clean_conflict_plugin() {
    local plugin_name="$1" found=0 pdir omz_dir matches
    if [[ -d "$ZINIT_PLUGINS_DIR" ]]; then
        for pdir in "$ZINIT_PLUGINS_DIR"/*"$plugin_name"*; do
            [[ -d "$pdir" ]] || continue
            found=1; warn "Found conflict plugin dir: $pdir"
        done
    fi
    omz_dir="$HOME/.oh-my-zsh/custom/plugins/$plugin_name"
    if [[ -d "$omz_dir" ]]; then found=1; warn "Found conflict plugin dir: $omz_dir"; fi
    if [[ -f "$HOME/.zshrc" ]]; then
        matches="$(grep -nF "$plugin_name" "$HOME/.zshrc" 2>/dev/null | grep -v '^[[:space:]]*#' || true)"
        [[ -n "$matches" ]] && found=1
    fi
    if (( found == 0 )); then
        success "No $plugin_name conflict detected"
        return 0
    fi
    if prompt_yes "Detected $plugin_name (conflicts with zsh-smart-complete). Remove it?" 1; then
        comment_out_zshrc "$plugin_name"
        if [[ -d "$ZINIT_PLUGINS_DIR" ]]; then
            for pdir in "$ZINIT_PLUGINS_DIR"/*"$plugin_name"*; do
                [[ -d "$pdir" ]] || continue
                mv "$pdir" "${pdir}.bak.$(date +%s)" && success "Backed up + removed: $pdir"
            done
        fi
        if [[ -d "$omz_dir" ]]; then
            mv "$omz_dir" "${omz_dir}.bak.$(date +%s)" && success "Backed up + removed: $omz_dir"
        fi
    else
        warn "Skipped $plugin_name removal; running it alongside zsh-smart-complete may cause duplicate suggestions / Tab conflicts."
    fi
}

# Config combo: zinit-starship (recommended) | keep-omz | zinit-p10k
CONFIG_COMBO="zinit-starship"

detect_env() {
    HAS_OMZ=0; HAS_P10K=0
    if [[ -d "$HOME/.oh-my-zsh" ]] || grep -qE 'oh-my-zsh(\.sh|/)|[$]ZSH/' "$HOME/.zshrc" 2>/dev/null; then
        HAS_OMZ=1
    fi
    if [[ -f "$HOME/.p10k.zsh" ]] || [[ -f "$HOME/.powerlevel10k/powerlevel10k.zsh-theme" ]] \
       || grep -qE 'powerlevel10k|p10k\.zsh' "$HOME/.zshrc" 2>/dev/null; then
        HAS_P10K=1
    fi
}

_remove_omz() {
    comment_out_zshrc 'oh-my-zsh'
    if [[ -d "$HOME/.oh-my-zsh" ]] && prompt_yes "Delete ~/.oh-my-zsh directory (backed up as .bak)?" 0; then
        mv "$HOME/.oh-my-zsh" "$HOME/.oh-my-zsh.bak.$(date +%s)" && success "Backed up + removed ~/.oh-my-zsh"
    fi
}
_remove_p10k() {
    comment_out_zshrc 'powerlevel10k'
    comment_out_zshrc 'p10k.zsh'
    if [[ -f "$HOME/.p10k.zsh" ]] && prompt_yes "Delete ~/.p10k.zsh (backed up)?" 0; then
        mv "$HOME/.p10k.zsh" "$HOME/.p10k.zsh.bak.$(date +%s)" && success "Backed up + removed ~/.p10k.zsh"
    fi
    if [[ -d "$HOME/.powerlevel10k" ]] && prompt_yes "Delete ~/.powerlevel10k directory (backed up)?" 0; then
        mv "$HOME/.powerlevel10k" "$HOME/.powerlevel10k.bak.$(date +%s)" && success "Removed ~/.powerlevel10k"
    fi
}

# --- 组合相关的"确保已安装"辅助函数（选择 OMZ / p10k 备选时，若未安装则安装）---
_set_zsh_theme() {
    local theme="$1" f="$HOME/.zshrc"
    [[ -f "$f" ]] || return 0
    if grep -qE '^[[:space:]]*ZSH_THEME=' "$f" 2>/dev/null; then
        local tmp="$(mktemp)"
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*ZSH_THEME= ]]; then
                printf 'ZSH_THEME="%s"\n' "$theme" >> "$tmp"
            else
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$f"
        cp -f "$f" "${f}.bak.$(date +%s)"
        mv -f "$tmp" "$f" 2>/dev/null || warn "写入 $f 失败，请手动设置 ZSH_THEME=\"$theme\""
        success "已设置 ZSH_THEME=\"$theme\""
    else
        printf 'ZSH_THEME="%s"\n' "$theme" >> "$f"
        success "已追加 ZSH_THEME=\"$theme\" 到 $f"
    fi
    return 0
}

_ensure_omz() {
    if [[ "$HAS_OMZ" == "1" ]]; then
        info "Oh My Zsh 已安装，保留。"
        return 0
    fi
    info "未检测到 Oh My Zsh，准备安装（官方一键脚本，走镜像加速）..."
    if ! prompt_yes "Install Oh My Zsh now?" 1; then
        warn "已跳过 Oh My Zsh 安装；将按 Zinit + Starship 组合继续。"
        return 0
    fi
    local omz_url="$(mirror_rewrite "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh")"
    if run_with_mirror_dl "sh -c \"\$(curl -fsSL ${omz_url})\" '' --unattended" 2>/dev/null; then
        success "Oh My Zsh 安装完成。"
        HAS_OMZ=1
    else
        warn "Oh My Zsh 安装失败（可能网络受限）；将按 Zinit + Starship 组合继续。"
    fi
    return 0
}

_ensure_p10k_omz() {
    if [[ "$HAS_P10K" == "1" ]]; then
        info "Powerlevel10k 已安装，保留。"
    else
        info "未检测到 Powerlevel10k，作为 Oh My Zsh 主题安装..."
        local p10k_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
        if git clone --depth 1 "$(mirror_rewrite "https://github.com/romkatzen/powerlevel10k.git")" "$p10k_dir" 2>/dev/null; then
            success "Powerlevel10k 已克隆到 $p10k_dir"
            HAS_P10K=1
        else
            warn "Powerlevel10k 克隆失败（可稍后手动安装）。"
        fi
    fi
    _set_zsh_theme "powerlevel10k/powerlevel10k"
    return 0
}

_ensure_p10k_zinit() {
    if [[ "$HAS_P10K" == "1" ]]; then
        info "Powerlevel10k 已安装，保留（将由 Zinit 加载）。"
    else
        info "Powerlevel10k 将由 Zinit 在首次启动时自动克隆并加载。"
    fi
    return 0
}

_apply_combo() {
    CONFIG_COMBO="$1"
    case "$CONFIG_COMBO" in
        keep-omz)
            info "已选择：Oh My Zsh + Powerlevel10k（经典方案）。"
            _ensure_omz
            _ensure_p10k_omz ;;
        zinit-p10k)
            info "已选择：Zinit + Powerlevel10k。"
            _remove_omz
            _ensure_p10k_zinit ;;
        zinit-starship)
            info "已选择（推荐）：Zinit + Starship。"
            _remove_omz
            _remove_p10k ;;
    esac
    return 0
}

resolve_omz_p10k() {
    detect_env
    # 环境变量覆盖：直接指定配置组合，跳过交互。
    if [[ -n "${SMART_INSTALL_COMBO:-}" ]]; then
        case "${SMART_INSTALL_COMBO}" in
            keep-omz|zinit-p10k|zinit-starship)
                _apply_combo "${SMART_INSTALL_COMBO}"
                info "配置组合（来自 SMART_INSTALL_COMBO）：${SMART_INSTALL_COMBO}"
                return 0 ;;
            *) warn "未知的 SMART_INSTALL_COMBO='${SMART_INSTALL_COMBO}'，忽略并回退到交互选择。" ;;
        esac
    fi
    if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
        _apply_combo "zinit-starship"
        info "(headless) 推荐配置：Zinit + Starship。"
        return 0
    fi

    # 无论是否已安装 OMZ/p10k，都给出组合选择；全部未安装时推荐 Zinit+Starship，
    # 同时分别提供 Oh My Zsh / Powerlevel10k 备选。
    echo
    info "选择配置组合（推荐 Zinit + Starship，也可选用 Oh My Zsh / Powerlevel10k 备选）："
    if (( HAS_OMZ == 0 && HAS_P10K == 0 )); then
        printf "  1) (推荐) Zinit + Starship —— 全新安装，轻量现代\n"
        printf "  2) Oh My Zsh + Powerlevel10k —— 经典方案（将为你安装 OMZ 与 p10k）\n"
        printf "  3) Zinit + Powerlevel10k —— Zinit 管理 p10k 主题\n"
    else
        local msg=""
        (( HAS_OMZ )) && msg+=" Oh My Zsh" || true
        (( HAS_P10K )) && msg+=" Powerlevel10k" || true
        info "已检测到已安装:${msg}。"
        printf "  1) (推荐) 移除 OMZ/p10k，全新 Zinit + Starship\n"
        printf "  2) 保留 OMZ + p10k，配合使用\n"
        printf "  3) 移除 OMZ，保留 p10k（Zinit + Powerlevel10k）\n"
    fi
    echo -n "输入序号 [默认=1]: "
    local REPLY
    read -r REPLY || true
    case "$REPLY" in
        2) _apply_combo "keep-omz" ;;
        3) _apply_combo "zinit-p10k" ;;
        *) _apply_combo "zinit-starship" ;;
    esac
    return 0
}

# First remove directly-conflicting plugins.
clean_conflict_plugin "zsh-autocomplete"
clean_conflict_plugin "zsh-autosuggestions"
# Then resolve OMZ / p10k combo.
resolve_omz_p10k

# Build the combo-aware prompt-init snippet written into the ~/.zshrc block.
zsc_prompt_snippet() {
    case "$CONFIG_COMBO" in
        zinit-p10k)
            PROMPT_INIT_SNIPPET='zinit ice depth=1
zinit light romkatzen/powerlevel10k
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh' ;;
        keep-omz)
            PROMPT_INIT_SNIPPET='# Powerlevel10k is managed by Oh My Zsh above; nothing to add here.' ;;
        *)
            PROMPT_INIT_SNIPPET='command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"
command -v zoxide   >/dev/null 2>&1 && eval "$(zoxide init zsh)"
command -v atuin    >/dev/null 2>&1 && eval "$(atuin init zsh --disable-up-arrow)"' ;;
    esac
}
zsc_prompt_snippet

# ------------------------------------------------------------------
# Phase 4/4: Configuration templates
# ------------------------------------------------------------------
info "=== Phase 4/4: Configuration templates ==="

# Helper: resolve a template file, preferring LOCAL clone over network.
resolve_template() {
    local name="$1"
    local dest_path="${2:-}"  # optional; only for error messages
    if (( HAS_LOCAL_TEMPLATES == 1 )) && [[ -f "${LOCAL_TEMPLATES_DIR}/${name}" ]]; then
        echo "LOCAL:${LOCAL_TEMPLATES_DIR}/${name}"
        return 0
    fi
    # Try download.
    local url="${REPO_BASE_URL}/templates/${name}"
    local tmp
    tmp="$(mktemp)"
    if curl_get -o "$tmp" "$url" 2>/dev/null; then
        echo "TMP:$tmp"
        return 0
    fi
    rm -f "$tmp"
    # Last resort: embed minimal inline fallback so install.sh still works
    # even with zero network access AND no local clone.
    echo "FALLBACK:$name"
    return 0
}

# Helper: install a template file from resolver output to dest.
apply_template() {
    local resolved="$1" dest="$2"
    case "$resolved" in
        LOCAL:*)   cp -f "${resolved#LOCAL:}" "$dest" ;;
        TMP:*)     mv -f "${resolved#TMP:}" "$dest" ;;
        FALLBACK:*)
            local n="${resolved#FALLBACK:}"
            case "$n" in
                zshrc.example)
                    cat > "$dest" <<'FALLBACK'
# Minimal .zshrc (installed offline fallback — upgrade via repo templates)
export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=1000000
export SAVEHIST=1000000
setopt appendhistory sharehistory histignorealldups
autoload -Uz compinit
compinit -d "${ZDOTDIR:-$HOME}/.zcompdump"
ZINIT_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/zinit.git"
[[ -f "$ZINIT_HOME/zinit.zsh" ]] && source "$ZINIT_HOME/zinit.zsh"
zinit ice wait lucid
zinit light zdharma-continuum/fast-syntax-highlighting
zinit light imonior/zsh-smart-complete
(( ${+functions[compdef]} )) && zinit cdreplay -q
command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"
command -v zoxide   >/dev/null 2>&1 && eval "$(zoxide init zsh)"
FALLBACK
                    ;;
                starship.toml.example)
                    cat > "$dest" <<'FALLBACK'
add_newline = false
[line_break]
disabled = true
[character]
success_symbol = "[❯](bold green)"
error_symbol   = "[❯](bold red)"
[directory]
truncation_length = 3
style = "bold cyan"
FALLBACK
                    ;;
            esac
            ;;
    esac
}

# ---------- Starship config ----------
STARSHIP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
STARSHIP_CONFIG_FILE="${STARSHIP_CONFIG_DIR}/starship.toml"
mkdir -p "$STARSHIP_CONFIG_DIR"

if [[ ! -f "$STARSHIP_CONFIG_FILE" ]]; then
    info "Generating $STARSHIP_CONFIG_FILE (recommended template)..."
    resolved_starship="$(resolve_template "starship.toml.example" "$STARSHIP_CONFIG_FILE")"
    apply_template "$resolved_starship" "$STARSHIP_CONFIG_FILE"
    success "Starship config installed"
else
    warn "Starship config exists: $STARSHIP_CONFIG_FILE"
    if prompt_yes "Overwrite with recommended template?" 0; then
        cp -f "$STARSHIP_CONFIG_FILE" "${STARSHIP_CONFIG_FILE}.bak.$(date +%s)"
        resolved_starship="$(resolve_template "starship.toml.example" "$STARSHIP_CONFIG_FILE")"
        apply_template "$resolved_starship" "$STARSHIP_CONFIG_FILE"
        success "Starship config updated (backup kept at .bak.*)"
    fi
fi

# ---------- .zshrc ----------
ZSHRC_FILE="${ZDOTDIR:-$HOME}/.zshrc"
ZSHRC_DIR="$(dirname "$ZSHRC_FILE")"
mkdir -p "$ZSHRC_DIR"

# Build the combo-aware zsh-smart-complete integration block (plain zsh code,
# written verbatim into ~/.zshrc). The prompt-init lines depend on CONFIG_COMBO.
build_zsc_integration() {
    cat <<'ZSC'
# ------------------------------
# zsh-smart-complete integration
# ------------------------------
# Ensure Zsh native completion is available (user side, not plugin side).
if ! (( ${+functions[compinit]} )); then
    autoload -Uz compinit
    compinit -d "${ZDOTDIR:-$HOME}/.zcompdump"
fi

ZINIT_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/zinit.git"
if [[ -f "$ZINIT_HOME/zinit.zsh" ]]; then
    source "$ZINIT_HOME/zinit.zsh"
    zinit ice wait lucid
    zinit light zdharma-continuum/fast-syntax-highlighting
    zinit light imonior/zsh-smart-complete
    # Only replay compdefs AFTER user (or we above) ran compinit.
    (( ${+functions[compdef]} )) && zinit cdreplay -q
fi

# External prompt (combo-aware)
ZSC
    echo "$PROMPT_INIT_SNIPPET"
}

if [[ ! -f "$ZSHRC_FILE" ]]; then
    info "No ~/.zshrc found — creating recommended one (with zsh-smart-complete block)..."
    cat > "$ZSHRC_FILE" <<'ZRCEOF'
export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=1000000
export SAVEHIST=1000000
setopt appendhistory sharehistory histignorealldups
autoload -Uz compinit
compinit -d "${ZDOTDIR:-$HOME}/.zcompdump"
ZRCEOF
    printf '%s\n' "$(build_zsc_integration)" >> "$ZSHRC_FILE"
    success ".zshrc created with zsh-smart-complete integration"
else
    if grep -q "zsh-smart-complete" "$ZSHRC_FILE"; then
        success ".zshrc already references zsh-smart-complete (skipping)"
    else
        if prompt_yes "Append zsh-smart-complete loader block to the end of ~/.zshrc?" 1; then
            cp -f "$ZSHRC_FILE" "${ZSHRC_FILE}.bak.$(date +%s)"
            printf '\n%s\n' "$(build_zsc_integration)" >> "$ZSHRC_FILE"
            success ".zshrc updated (backup kept at .bak.*)"
        fi
    fi
fi

# ------------------------------------------------------------------
# Final banner
# ------------------------------------------------------------------
echo
echo "============================================================"
echo -e "${GREEN}  🎉 zsh-smart-complete installer finished${NC}"
echo "============================================================"
echo
echo "To reload with the new config, run:"
echo -e "  ${BLUE}exec zsh${NC}"
echo
echo "Then try:"
echo "  git s  [Tab]   → native completion (menu)"
echo "  git s  [→]     → inline suggestion accept"
echo "  git s  [↑]     → native history navigation"
echo
