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
    read -r -n 1 REPLY; echo
    [[ -z "$REPLY" ]] && REPLY=""
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

REPO_BASE_URL="${SMART_COMPLETE_REPO_BASE_URL:-https://raw.githubusercontent.com/imonior/zsh-smart-complete/main}"

# Curl with sane defaults: 15s connect + max 120s, no progress, fail on 4xx/5xx.
curl_get() {
    curl -fsSL --connect-timeout 15 --max-time 120 "$@"
}

# ------------------------------------------------------------------
# 1. Detect OS
# ------------------------------------------------------------------
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
    error "Unsupported operating system. This installer supports macOS (Homebrew) and Ubuntu/Debian (apt)."
fi
info "Detected OS: $OS_TYPE"

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

# ------------------------------------------------------------------
# Phase 1/4: Base tools (zsh, fzf)
# ------------------------------------------------------------------
info "=== Phase 1/4: Base dependencies ==="

if ! command -v zsh >/dev/null 2>&1; then
    install_or_upgrade_pkg "zsh" "zsh" "zsh"
    info "Setting Zsh as default shell ..."
    USER_SHELL="$(command -v zsh)"
    if [[ -n "$USER_SHELL" ]]; then
        if grep -qxF "$USER_SHELL" /etc/shells 2>/dev/null; then
            chsh -s "$USER_SHELL" 2>/dev/null || warn "Could not change default shell (chsh). Please run chsh manually."
        else
            warn "$USER_SHELL not in /etc/shells. Skipping chsh."
        fi
    fi
else
    success "Zsh is installed: $(zsh --version | head -n 1)"
fi

if [[ "${SKIP_DEPS:-0}" != "1" ]]; then
    install_or_upgrade_pkg "fzf" "fzf" "fzf"
fi

# ------------------------------------------------------------------
# Phase 2/4: Optional Starship (system package)
# ------------------------------------------------------------------
info "=== Phase 2/4: Starship prompt ==="
if command -v starship >/dev/null 2>&1; then
    success "Starship is installed: $(starship --version 2>/dev/null || echo present)"
    if prompt_yes "Upgrade Starship?" 0; then
        curl_get https://starship.rs/install.sh | sh -s -- -y || warn "Starship upgrade failed (non-fatal)"
    fi
elif [[ "${SKIP_DEPS:-0}" != "1" ]] && prompt_yes "Install Starship prompt (recommended)?" 1; then
    curl_get https://starship.rs/install.sh | sh -s -- -y \
        || error "Starship install failed. Retry with SKIP_DEPS=1 to skip external downloads."
    success "Starship installed"
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
    git clone --depth 1 https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME" \
        || error "Zinit clone failed. Check your internet connection."
    success "Zinit installed"
fi

# If the user didn't install Zinit, fall back: clone zsh-smart-complete directly
# so we can still provide a working `source ~/.../zsh-smart-complete.plugin.zsh`.
SMART_COMPLETE_INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/plugins/imonior---zsh-smart-complete"
if [[ ! -d "$SMART_COMPLETE_INSTALL_DIR" && "${SKIP_DEPS:-0}" != "1" ]]; then
    info "Cloning zsh-smart-complete plugin repo ..."
    mkdir -p "$(dirname "$SMART_COMPLETE_INSTALL_DIR")"
    git clone --depth 1 https://github.com/imonior/zsh-smart-complete.git "$SMART_COMPLETE_INSTALL_DIR" \
        || warn "zsh-smart-complete clone failed. If running Zinit, zinit light will clone it automatically."
fi

# ------------------------------------------------------------------
# Conflict cleanup
# ------------------------------------------------------------------
info "=== Conflict cleanup ==="
ZINIT_PLUGINS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/plugins"

clean_conflict_plugin() {
    local plugin_name="$1"
    local found=0

    if [[ -d "$ZINIT_PLUGINS_DIR" ]]; then
        local pdir
        for pdir in "$ZINIT_PLUGINS_DIR"/*"$plugin_name"*; do
            [[ -d "$pdir" ]] || continue
            found=1
            warn "Found conflict plugin: $pdir"
            if prompt_yes "Remove $plugin_name directory (keeps backups, cannot be undone)?" 0; then
                local backup="${pdir}.bak.$(date +%s)"
                mv "$pdir" "$backup" && success "Backed up to $backup"
            fi
        done
    fi

    if [[ -f "$HOME/.zshrc" ]]; then
        # Only flag actual loader lines — not comments / inline mentions.
        # Patterns that actually enable the plugin:
        #   zinit (ice ...) (light|load|snippet) ...$plugin_name
        #   source ...$plugin_name
        #   antidote/znap/etc. load lines.
        local matches
        matches="$(grep -En "^[[:space:]]*(zinit|znap|antidote|antigen|plug)[[:space:]].*${plugin_name}|^[[:space:]]*(source|\\.)[[:space:]].*${plugin_name}" "$HOME/.zshrc" 2>/dev/null || true)"
        if [[ -n "$matches" ]]; then
            warn "Your ~/.zshrc contains an active loader for '$plugin_name':"
            while IFS= read -r line; do [[ -n "$line" ]] && warn "  $line"; done <<< "$matches"
            warn "Please edit ~/.zshrc and remove these lines."
        fi
    fi

    (( found == 0 )) && success "No $plugin_name conflict detected"
}

clean_conflict_plugin "zsh-autocomplete"
clean_conflict_plugin "zsh-autosuggestions"

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

if [[ ! -f "$ZSHRC_FILE" ]]; then
    info "No ~/.zshrc found — installing recommended template..."
    resolved_zshrc="$(resolve_template "zshrc.example" "$ZSHRC_FILE")"
    apply_template "$resolved_zshrc" "$ZSHRC_FILE"
    success ".zshrc installed from template"
else
    if grep -q "zsh-smart-complete" "$ZSHRC_FILE"; then
        success ".zshrc already references zsh-smart-complete (skipping)"
    else
        if prompt_yes "Append zsh-smart-complete loader block to the end of ~/.zshrc?" 1; then
            cp -f "$ZSHRC_FILE" "${ZSHRC_FILE}.bak.$(date +%s)"
            cat >> "$ZSHRC_FILE" <<'APPEND'

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

# External tools (system/Homebrew-managed). Keep out of Zinit's scope.
command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"
command -v zoxide   >/dev/null 2>&1 && eval "$(zoxide init zsh)"
command -v atuin    >/dev/null 2>&1 && eval "$(atuin init zsh --disable-up-arrow)"
APPEND
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
