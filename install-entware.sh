#!/usr/bin/env bash
# ============================================================
# zsh-smart-complete — Entware / QNAP / OpenWrt Installer
#
# Dedicated installer for Entware environments (QNAP NAS, and other
# opkg-based systems such as OpenWrt). Delegated to by install.sh
# when `opkg` is detected; also runnable standalone:
#
#   bash install-entware.sh                       # interactive
#   NONINTERACTIVE=1 bash install-entware.sh      # headless / CI
#   SKIP_DEPS=1       bash install-entware.sh     # no network downloads
#
# Key differences from the main (macOS/Debian) installer:
#   * Package manager is `opkg` (not apt / brew).
#   * Runs as the NAS admin (root) — NO `sudo`.
#   * No /etc/shells and no `chsh` — the login shell is switched via a
#     guarded `exec zsh` snippet we append to ~/.profile, or via the QNAP
#     GUI (Control Panel → Terminal → Default shell).
#   * fzf / starship are OPTIONAL and skipped if not in the entware feed,
#     because the plugin core does not require them.
#
# Optional components and settings (fzf-tab, the single-column popup,
# recent-directory candidates, ↑/↓ history search, zsh-vi-mode, the suggestion
# source) are ASKED during the install and the answers are written as plain
# `export`s into a managed block in ~/.zshrc. NONINTERACTIVE=1 takes the
# documented defaults.
#   * Entware binaries live under /opt/bin.
# ============================================================

# Re-exec under Entware's bash if the current shell lacks arrays / [[ ]].
if [[ -z "${BASH_VERSION:-}" ]] && [[ -x /opt/bin/bash ]]; then
    exec /opt/bin/bash "$0" "$@"
fi

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

# Read from /dev/tty when available. Needed because the documented one-liner
# pipes the script into bash (`curl -fsSL … | bash`), and then stdin IS the
# script: every plain `read` returns an empty line at once and each prompt
# silently takes its default (measured: the language and mirror menus never
# waited for input). Falls back to stdin when /dev/tty is unavailable, which
# keeps NONINTERACTIVE / CI runs working.
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
    # Otherwise stdin is a pipe/file; try the controlling terminal /dev/tty.
    # No timeout — block until the user answers.
    if [[ -c /dev/tty ]] && read "$@" </dev/tty 2>/dev/null; then
        return 0
    fi
    # Last resort: stdin (may be EOF in non-interactive contexts → default).
    if read "$@" 2>/dev/null; then
        return 0
    fi
    REPLY=""; return 1
}

# Prompts: respect NONINTERACTIVE=1 (assume "yes for safe, no for destructive")
prompt_yes() {
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
    _tty_read -r -n 1 REPLY || REPLY=""; echo
    case "$REPLY" in
        y|Y) return 0 ;;
        n|N) return 1 ;;
        "")  [[ "$default_yes" == "1" ]] && return 0 || return 1 ;;
        *)   return 1 ;;
    esac
}

# ------------------------------------------------------------------
# i18n：安装语言（默认 English，可选 简体中文 / 繁體中文 / 日本語 / 한국어）
# 设计：msg <key> [args...] 查表；未收录的键自动回退英文，
# 因此增量补翻译不会破坏流程。兼容 bash 3.2（不使用关联数组）。
# ------------------------------------------------------------------
LANG_CODE="${SMART_INSTALL_LANG:-en}"

_msg() {
    local key="$1" lang="${LANG_CODE:-en}" s=""
    case "$key" in
        lang.title)
            case "$lang" in
                zh-CN) s="请选择安装语言：" ;; zh-TW) s="請選擇安裝語言：" ;;
                ja)    s="インストール言語を選択してください：" ;;
                ko)    s="설치 언어를 선택하세요:" ;;
                *)     s="Select installation language:" ;;
            esac ;;
        lang.prompt)
            case "$lang" in
                zh-CN) s="请输入序号 [默认=1 English]: " ;; zh-TW) s="請輸入編號 [預設=1 English]: " ;;
                ja)    s="番号を入力 [既定=1 English]: " ;;
                ko)    s="번호 입력 [기본=1 English]: " ;;
                *)     s="Enter number [default=1 English]: " ;;
            esac ;;
        lang.chosen)
            case "$lang" in
                zh-CN) s="已选择语言：%s" ;; zh-TW) s="已選擇語言：%s" ;;
                ja)    s="言語: %s" ;; ko)    s="언어: %s" ;;
                *)     s="Language: %s" ;;
            esac ;;
        os.detected)
            case "$lang" in
                zh-CN) s="检测到操作系统：%s" ;; zh-TW) s="偵測到作業系統：%s" ;;
                ja)    s="OS を検出: %s" ;; ko)    s="OS 감지: %s" ;;
                *)     s="Detected OS: %s" ;;
            esac ;;
        mirror.test)
            case "$lang" in
                zh-CN) s="=== GitHub 加速镜像测速 ===" ;; zh-TW) s="=== GitHub 加速鏡像測速 ===" ;;
                ja)    s="=== GitHub ミラー速度測定 ===" ;;
                ko)    s="=== GitHub 미러 속도 측정 ===" ;;
                *)     s="=== GitHub mirror speed test ===" ;;
            esac ;;
        mirror.select)
            case "$lang" in
                zh-CN) s="请选择 GitHub 加速镜像（已列出当前可用候选的测速结果）：" ;;
                zh-TW) s="請選擇 GitHub 加速鏡像（已列出目前可用候選的測速結果）：" ;;
                ja)    s="GitHub ミラーを選択してください（利用可能な候補の実測値を表示）：" ;;
                ko)    s="GitHub 미러를 선택하세요 (현재 사용 가능한 후보의 측정 결과 표시):" ;;
                *)     s="Select a GitHub mirror (available candidates with measured latency):" ;;
            esac ;;
        mirror.manual)
            case "$lang" in
                zh-CN) s="手动输入镜像源（URL 前缀 / 域名替换主机）" ;; zh-TW) s="手動輸入鏡像源（URL 前綴 / 網域替換主機）" ;;
                ja)    s="ミラー源を手動入力（URL プレフィックス / ドメイン置換ホスト）" ;;
                ko)    s="미러 소스 직접 입력 (URL 접두사 / 도메인 교체 호스트)" ;;
                *)     s="Enter a mirror source manually (URL prefix / domain swap host)" ;;
            esac ;;
        mirror.manual_proxy)
            case "$lang" in
                zh-CN) s="手动输入全量代理服务器（系统代理，如 http://127.0.0.1:7890）" ;;
                zh-TW) s="手動輸入全量代理伺服器（系統代理，如 http://127.0.0.1:7890）" ;;
                ja)    s="フルプロキシを手動入力（システムプロキシ、例: http://127.0.0.1:7890）" ;;
                ko)    s="전체 프록시 서버 직접 입력 (시스템 프록시, 예: http://127.0.0.1:7890)" ;;
                *)     s="Enter a full proxy server manually (system proxy, e.g. http://127.0.0.1:7890)" ;;
            esac ;;
        mirror.prompt)
            case "$lang" in
                zh-CN) s="请输入序号 [默认=%s (推荐)]: " ;; zh-TW) s="請輸入編號 [預設=%s (推薦)]: " ;;
                ja)    s="番号を入力 [既定=%s (推奨)]: " ;;
                ko)    s="번호 입력 [기본=%s (추천)]: " ;;
                *)     s="Enter number [default=%s (recommended)]: " ;;
            esac ;;
        mirror.chosen)
            case "$lang" in
                zh-CN) s="已选择：%s (%ss) [%s]" ;; zh-TW) s="已選擇：%s (%ss) [%s]" ;;
                ja)    s="選択: %s (%ss) [%s]" ;; ko)    s="선택: %s (%ss) [%s]" ;;
                *)     s="Selected: %s (%ss) [%s]" ;;
            esac ;;
        proxy.prompt)
            case "$lang" in
                zh-CN) s="请输入全量代理地址（如 http://127.0.0.1:7890、socks5://127.0.0.1:1080）: " ;;
                zh-TW) s="請輸入全量代理位址（如 http://127.0.0.1:7890、socks5://127.0.0.1:1080）: " ;;
                ja)    s="フルプロキシのアドレスを入力（例: http://127.0.0.1:7890、socks5://127.0.0.1:1080）: " ;;
                ko)    s="전체 프록시 주소 입력 (예: http://127.0.0.1:7890, socks5://127.0.0.1:1080): " ;;
                *)     s="Enter full proxy address (e.g. http://127.0.0.1:7890, socks5://127.0.0.1:1080): " ;;
            esac ;;
        proxy.testing)
            case "$lang" in
                zh-CN) s="正在检测该代理是否可用 ..." ;; zh-TW) s="正在檢測該代理是否可用 ..." ;;
                ja)    s="このプロキシが利用可能か検出中 ..." ;;
                ko)    s="프록시 사용 가능 여부 감지 중 ..." ;;
                *)     s="Testing whether the proxy works ..." ;;
            esac ;;
        proxy.chosen)
            case "$lang" in
                zh-CN) s="已启用全量代理：%s（已导出 HTTP_PROXY/HTTPS_PROXY，curl/git/wget 均会走它）" ;;
                zh-TW) s="已啟用全量代理：%s（已匯出 HTTP_PROXY/HTTPS_PROXY，curl/git/wget 均會走它）" ;;
                ja)    s="フルプロキシを有効化: %s（HTTP_PROXY/HTTPS_PROXY をエクスポート済み。curl/git/wget が使用）" ;;
                ko)    s="전체 프록시 활성화: %s (HTTP_PROXY/HTTPS_PROXY 내보냄. curl/git/wget 적용)" ;;
                *)     s="Full proxy enabled: %s (exported HTTP_PROXY/HTTPS_PROXY; used by curl/git/wget)" ;;
            esac ;;
        proxy.test_failed)
            case "$lang" in
                zh-CN) s="该代理未通过可用性检测：%s" ;; zh-TW) s="該代理未通過可用性檢測：%s" ;;
                ja)    s="このプロキシは可用性チェックに失敗しました: %s" ;;
                ko)    s="이 프록시는 가용성 검사를 통과하지 못했습니다: %s" ;;
                *)     s="The proxy failed the reachability test: %s" ;;
            esac ;;
        proxy.keep_ask)
            case "$lang" in
                zh-CN) s="仍要使用它吗？[y/N]: " ;; zh-TW) s="仍要使用它嗎？[y/N]: " ;;
                ja)    s="それでも使用しますか？[y/N]: " ;;
                ko)    s="그래도 사용하시겠습니까? [y/N]: " ;;
                *)     s="Still use it? [y/N]: " ;;
            esac ;;
        proxy.empty)
            case "$lang" in
                zh-CN) s="输入为空，已取消使用全量代理。" ;; zh-TW) s="輸入為空，已取消使用全量代理。" ;;
                ja)    s="入力が空のため、フルプロキシの使用を取り消しました。" ;;
                ko)    s="입력이 비어 있어 전체 프록시 사용을 취소했습니다." ;;
                *)     s="Empty input; cancelled using a full proxy." ;;
            esac ;;
        region.test)
            case "$lang" in
                zh-CN) s="正在检测外网 IP 归属地 ..." ;; zh-TW) s="正在檢測外網 IP 歸屬地 ..." ;;
                ja)    s="外部 IP の帰属を検出中 ..." ;;
                ko)    s="외부 IP 소속 감지 중 ..." ;;
                *)     s="Detecting public IP geo-location ..." ;;
            esac ;;
        region.cn)
            case "$lang" in
                zh-CN) s="当前网络属于中国区，建议走代理/镜像加速。外网 IP：%s" ;;
                zh-TW) s="當前網路屬於中國區，建議走代理/鏡像加速。外網 IP：%s" ;;
                ja)    s="現在のネットワークは中国圏です。プロキシ/ミラー高速化を推奨します。外部 IP: %s" ;;
                ko)    s="현재 네트워크는 중국 지역입니다. 프록시/미러 가속 권장. 외부 IP: %s" ;;
                *)     s="Network appears to be in China region; a proxy/mirror is recommended. Public IP: %s" ;;
            esac ;;
        region.foreign)
            case "$lang" in
                zh-CN) s="当前网络非中国区，direct 直连可用。外网 IP：%s" ;;
                zh-TW) s="當前網路非中國區，direct 直連可用。外網 IP：%s" ;;
                ja)    s="中国圏外のネットワークです。direct 接続が利用可能です。外部 IP: %s" ;;
                ko)    s="중국 외 지역 네트워크입니다. direct 직접 연결 사용 가능. 외부 IP: %s" ;;
                *)     s="Network is outside China region; direct connection works. Public IP: %s" ;;
            esac ;;
        region.direct_ok)
            case "$lang" in
                zh-CN) s="非中国大陆网络：已隐藏适用于中国大陆的预置镜像（仅保留直连），仍会对直连测速，并保留两项手动输入。" ;;
                zh-TW) s="非中國大陸網路：已隱藏適用於中國大陸的預置鏡像（僅保留直連），仍會對直連測速，並保留兩項手動輸入。" ;;
                ja)    s="中国大陸以外のネットワーク: 中国大陸向けプリセットミラーは非表示（直接続のみ）。direct も速度測定し、手動入力2項目も維持します。" ;;
                ko)    s="중국 본토 외 네트워크: 중국 본토용 프리셋 미러는 숨김(직접 연결만 유지). direct도 속도 측정하고 수동 입력 2개도 유지합니다." ;;
                *)     s="Outside mainland China: preset China-only mirrors are hidden (direct kept); direct is still speed-tested and both manual entries stay available." ;;
            esac ;;
        region.unknown)
            case "$lang" in
                zh-CN) s="无法检测外网 IP 归属地，保守走镜像测速流程。" ;;
                zh-TW) s="無法檢測外網 IP 歸屬地，保守走鏡像測速流程。" ;;
                ja)    s="外部 IP の帰属を検出できません。安全のためミラー速度測定を行います。" ;;
                ko)    s="외부 IP 소속을 감지할 수 없습니다. 안전을 위해 미러 속도 측정 진행." ;;
                *)     s="Could not detect public IP geo-location; conservatively running mirror speed test." ;;
            esac ;;
        region.proxy)
            case "$lang" in
                zh-CN) s="检测到代理环境变量（透明作用于 git/curl）：HTTP_PROXY=%s HTTPS_PROXY=%s" ;;
                zh-TW) s="偵測到代理環境變數（透明作用於 git/curl）：HTTP_PROXY=%s HTTPS_PROXY=%s" ;;
                ja)    s="プロキシ環境変数を検出（git/curl に透過適用）：HTTP_PROXY=%s HTTPS_PROXY=%s" ;;
                ko)    s="프록시 환경변수 감지 (git/curl에 투명 적용): HTTP_PROXY=%s HTTPS_PROXY=%s" ;;
                *)     s="Detected proxy env vars (transparently applied to git/curl): HTTP_PROXY=%s HTTPS_PROXY=%s" ;;
            esac ;;
        region.proxy_none)
            case "$lang" in
                zh-CN) s="未检测到代理环境变量。如需使用自有代理，请先 export HTTP_PROXY/HTTPS_PROXY。" ;;
                zh-TW) s="未偵測到代理環境變數。如需使用自有代理，請先 export HTTP_PROXY/HTTPS_PROXY。" ;;
                ja)    s="プロキシ環境変数は検出されませんでした。独自プロキシを使う場合は export HTTP_PROXY/HTTPS_PROXY を先に。" ;;
                ko)    s="프록시 환경변수 미감지. 자체 프록시 사용 시 먼저 export HTTP_PROXY/HTTPS_PROXY 하세요." ;;
                *)     s="No proxy env vars detected. To use your own proxy, export HTTP_PROXY/HTTPS_PROXY first." ;;
            esac ;;
        phase1)
            case "$lang" in
                zh-CN) s="=== 阶段 1/4：基础依赖 ===" ;; zh-TW) s="=== 階段 1/4：基礎依賴 ===" ;;
                ja)    s="=== フェーズ 1/4: 基本依存関係 ===" ;;
                ko)    s="=== 단계 1/4: 기본 종속성 ===" ;;
                *)     s="=== Phase 1/4: Base dependencies ===" ;;
            esac ;;
        phase2)
            case "$lang" in
                zh-CN) s="=== 阶段 2/4：Starship 提示符 ===" ;; zh-TW) s="=== 階段 2/4：Starship 提示符 ===" ;;
                ja)    s="=== フェーズ 2/4: Starship プロンプト ===" ;;
                ko)    s="=== 단계 2/4: Starship 프롬프트 ===" ;;
                *)     s="=== Phase 2/4: Starship prompt ===" ;;
            esac ;;
        phase2b)
            case "$lang" in
                zh-CN) s="=== 阶段 2b/4：Atuin 历史记录（可选）===" ;;
                zh-TW) s="=== 階段 2b/4：Atuin 歷史記錄（可選）===" ;;
                ja)    s="=== フェーズ 2b/4: Atuin 履歴（オプション）===" ;;
                ko)    s="=== 단계 2b/4: Atuin 히스토리 (선택) ===" ;;
                *)     s="=== Phase 2b/4: Atuin shell history (optional) ===" ;;
            esac ;;
        phase3)
            case "$lang" in
                zh-CN) s="=== 阶段 3/4：Zinit 插件管理器 ===" ;; zh-TW) s="=== 階段 3/4：Zinit 套件管理器 ===" ;;
                ja)    s="=== フェーズ 3/4: Zinit プラグインマネージャー ===" ;;
                ko)    s="=== 단계 3/4: Zinit 플러그인 관리자 ===" ;;
                *)     s="=== Phase 3/4: Zinit plugin manager ===" ;;
            esac ;;
        phase4)
            case "$lang" in
                zh-CN) s="=== 阶段 4/4：配置模板 ===" ;; zh-TW) s="=== 階段 4/4：設定範本 ===" ;;
                ja)    s="=== フェーズ 4/4: 設定テンプレート ===" ;;
                ko)    s="=== 단계 4/4: 설정 템플릿 ===" ;;
                *)     s="=== Phase 4/4: Configuration templates ===" ;;
            esac ;;
        phase.cleanup)
            case "$lang" in
                zh-CN) s="=== 冲突清理与环境检测 ===" ;; zh-TW) s="=== 衝突清理與環境偵測 ===" ;;
                ja)    s="=== 競合クリーンアップと環境検出 ===" ;;
                ko)    s="=== 충돌 정리 및 환경 감지 ===" ;;
                *)     s="=== Conflict cleanup & environment detection ===" ;;
            esac ;;
        prompt.starship)
            case "$lang" in
                zh-CN) s="安装 Starship 提示符？（推荐）" ;; zh-TW) s="安裝 Starship 提示符？（推薦）" ;;
                ja)    s="Starship プロンプトをインストールしますか？（推奨）" ;;
                ko)    s="Starship 프롬프트를 설치할까요? (권장)" ;;
                *)     s="Install Starship prompt (recommended)?" ;;
            esac ;;
        prompt.starship_upgrade)
            case "$lang" in
                zh-CN) s="升级 Starship？" ;; zh-TW) s="升級 Starship？" ;;
                ja)    s="Starship をアップグレードしますか？" ;;
                ko)    s="Starship 업그레이드?" ;;
                *)     s="Upgrade Starship?" ;;
            esac ;;
        prompt.atuin)
            case "$lang" in
                zh-CN) s="安装 Atuin 历史记录同步（可选）？" ;; zh-TW) s="安裝 Atuin 歷史記錄同步（可選）？" ;;
                ja)    s="Atuin 履歴同期をインストールしますか？（オプション）" ;;
                ko)    s="Atuin 히스토리 동기화 설치? (선택)" ;;
                *)     s="Install Atuin shell-history sync (optional)?" ;;
            esac ;;
        prompt.zinit)
            case "$lang" in
                zh-CN) s="安装 Zinit 插件管理器？（zinit-light 方式必需）" ;;
                zh-TW) s="安裝 Zinit 套件管理器？（zinit-light 方式必需）" ;;
                ja)    s="Zinit プラグインマネージャーをインストールしますか？（zinit-light に必要）" ;;
                ko)    s="Zinit 플러그인 관리자 설치? (zinit-light 필요)" ;;
                *)     s="Install Zinit plugin manager (required for zinit-light method)?" ;;
            esac ;;
        prompt.zinit_pull)
            case "$lang" in
                zh-CN) s="拉取最新 Zinit？" ;; zh-TW) s="拉取最新 Zinit？" ;;
                ja)    s="最新の Zinit を取得しますか？" ;; ko)    s="최신 Zinit 가져오기?" ;;
                *)     s="Pull latest Zinit?" ;;
            esac ;;
        prompt.remove_plugin)
            case "$lang" in
                zh-CN) s="检测到 %s（与 zsh-smart-complete 冲突）。是否移除？" ;;
                zh-TW) s="偵測到 %s（與 zsh-smart-complete 衝突）。是否移除？" ;;
                ja)    s="%s を検出しました（zsh-smart-complete と競合）。削除しますか？" ;;
                ko)    s="%s 감지됨 (zsh-smart-complete 와 충돌). 제거할까요?" ;;
                *)     s="Detected %s (conflicts with zsh-smart-complete). Remove it?" ;;
            esac ;;
        cleanup.scan_other_rcs_head)
            case "$lang" in
                zh-CN) s="在其它启动文件（非 ~/.zshrc）中发现冲突插件的加载行。安装器未修改这些文件——请注释或删除下列行，否则每次 exec zsh 仍会加载它们，可能再次触发重复建议或 Tab 冲突：" ;;
                zh-TW) s="在其它啟動檔（非 ~/.zshrc）中發現衝突套件的載入行。安裝器未修改這些檔案——請註解或刪除下列行，否則每次 exec zsh 仍會載入它們，可能再次觸發重複建議或 Tab 衝突：" ;;
                ja)    s="其它の起動ファイル（~/.zshrc 以外）に競合プラグインのロード行があります。インストーラーはこれらを編集しません——下の行をコメントアウト／削除してください。さもなくば毎回 exec zsh で読み込まれ、重複提案や Tab 競合が再発する恐れがあります：" ;;
                ko)    s="다른 시작 파일(~/.zshrc 제외)에서 충돌 플러그인 로드 행을 찾았습니다. 설치기는 이 파일을 수정하지 않습니다——아래 행을 주석 처리/삭제하세요. 그렇지 않으면 매 exec zsh 마다 로드되어 중복 제안이나 Tab 충돌이 재발할 수 있습니다:" ;;
                *)     s="Found loader lines for conflicting plugins in OTHER startup files (not ~/.zshrc). The installer did NOT edit these — please comment out / remove the lines below, or they will keep loading on every 'exec zsh' and may re-trigger duplicate suggestions or Tab conflicts:" ;;
            esac ;;
        cleanup.scan_other_rcs_line)
            case "$lang" in
                *) s="  > %s:%s" ;;
            esac ;;
        cleanup.scan_other_rcs_hint)
            case "$lang" in
                zh-CN) s="请编辑上述每个文件，注释或删除匹配的行，然后运行 exec zsh 确认重复框已消失。" ;;
                zh-TW) s="請編輯上述每個檔案，註解或刪除符合的行，然後執行 exec zsh 確認重複框已消失。" ;;
                ja)    s="上記の各ファイルを編集し、該当行をコメントアウト／削除してから exec zsh で重複ボックスが消えたことを確認してください。" ;;
                ko)    s="위 각 파일을 편집해 해당 행을 주석 처리/삭제한 뒤 exec zsh 로 중복 박스가 사라졌는지 확인하세요." ;;
                *)     s="Edit each file above, comment out or delete the matching line, then run 'exec zsh' to confirm the duplicate box is gone." ;;
            esac ;;
        cleanup.scan_other_rcs_clean)
            case "$lang" in
                zh-CN) s="其它启动文件（.zprofile/.zshenv/conf.d/.zshrc.d/etc/zsh/zshrc）中未发现冲突加载行。" ;;
                zh-TW) s="其它啟動檔（.zprofile/.zshenv/conf.d/.zshrc.d/etc/zsh/zshrc）中未發現衝突載入行。" ;;
                ja)    s="其它の起動ファイル（.zprofile/.zshenv/conf.d/.zshrc.d/etc/zsh/zshrc）に競合ロード行はありません。" ;;
                ko)    s="다른 시작 파일(.zprofile/.zshenv/conf.d/.zshrc.d/etc/zsh/zshrc)에서 충돌 로드 행을 찾지 못했습니다." ;;
                *)     s="No conflicting loaders found in other startup files (.zprofile/.zshenv/conf.d/.zshrc.d/etc/zsh/zshrc)." ;;
            esac ;;
        prompt.omz)
            case "$lang" in
                zh-CN) s="现在安装 Oh My Zsh？" ;; zh-TW) s="現在安裝 Oh My Zsh？" ;;
                ja)    s="Oh My Zsh を今すぐインストールしますか？" ;;
                ko)    s="Oh My Zsh 지금 설치할까요?" ;;
                *)     s="Install Oh My Zsh now?" ;;
            esac ;;
        prompt.zshrc_append)
            case "$lang" in
                zh-CN) s="将 zsh-smart-complete 加载块追加到 ~/.zshrc 末尾？" ;;
                zh-TW) s="將 zsh-smart-complete 載入區塊附加到 ~/.zshrc 結尾？" ;;
                ja)    s="zsh-smart-complete のロードブロックを ~/.zshrc の末尾に追記しますか？" ;;
                ko)    s="zsh-smart-complete 로더 블록을 ~/.zshrc 끝에 추가할까요?" ;;
                *)     s="Append zsh-smart-complete loader block to the end of ~/.zshrc?" ;;
            esac ;;
        prompt.fzf)
            case "$lang" in
                zh-CN) s="fzf 未安装，要现在安装吗？" ;; zh-TW) s="fzf 未安裝，要現在安裝嗎？" ;;
                ja)    s="fzf が未インストールです。インストールしますか？" ;;
                ko)    s="fzf가 설치되지 않았습니다. 설치할까요?" ;;
                *)     s="fzf not installed. Install now?" ;;
            esac ;;
        prompt.fzf_reinstall)
            case "$lang" in
                zh-CN) s="重新安装 fzf？" ;; zh-TW) s="重新安裝 fzf？" ;;
                ja)    s="fzf を再インストールしますか？" ;;
                ko)    s="fzf 재설치?" ;;
                *)     s="Reinstall fzf?" ;;
            esac ;;
        prompt.starship_reinstall)
            case "$lang" in
                zh-CN) s="重新安装 Starship？" ;; zh-TW) s="重新安裝 Starship？" ;;
                ja)    s="Starship を再インストールしますか？" ;;
                ko)    s="Starship 재설치?" ;;
                *)     s="Reinstall Starship?" ;;
            esac ;;
        prompt.config_backup)
            case "$lang" in
                zh-CN) s="备份现有配置并新建？" ;; zh-TW) s="備份現有配置並新建？" ;;
                ja)    s="既存設定をバックアップして新規作成しますか？" ;;
                ko)    s="기존 설정을 백업하고 새로 만질까요?" ;;
                *)     s="Backup existing config and create new?" ;;
            esac ;;
        prompt.config_keep)
            case "$lang" in
                zh-CN) s="保留现有配置不动？" ;; zh-TW) s="保留現有配置不動？" ;;
                ja)    s="既存設定をそのまま保持しますか？" ;;
                ko)    s="기존 설정을 그대로 유지할까요?" ;;
                *)     s="Keep existing config as-is?" ;;
            esac ;;
        msg.fzf_reinstalled)
            case "$lang" in
                zh-CN) s="fzf 已重装" ;; zh-TW) s="fzf 已重裝" ;; ja)    s="fzf を再インストールしました" ;; ko) s="fzf 재설치 완료" ;;
                *)     s="fzf reinstalled" ;;
            esac ;;
        msg.starship_reinstalled)
            case "$lang" in
                zh-CN) s="Starship 已重装" ;; zh-TW) s="Starship 已重裝" ;; ja)    s="Starship を再インストールしました" ;; ko) s="Starship 재설치 완료" ;;
                *)     s="Starship reinstalled" ;;
            esac ;;
        msg.config_backup_done)
            case "$lang" in
                zh-CN) s="已备份现有配置: %s" ;; zh-TW) s="已備份現有配置: %s" ;; ja)    s="既存設定をバックアップ: %s" ;; ko) s="기존 설정 백업 완료: %s" ;;
                *)     s="Backed up existing config: %s" ;;
            esac ;;
        phase4.config_choice)
            case "$lang" in
                zh-CN) s="请选择 ~/.zshrc 处理方式：" ;; zh-TW) s="請選擇 ~/.zshrc 處理方式：" ;;
                ja)    s="~/.zshrc の処理方法を選択してください：" ;;
                ko)    s="~/.zshrc 처리 방식을 선택하세요:" ;;
                *)     s="Select ~/.zshrc handling option:" ;;
            esac ;;
        msg.fzf_installed)
            case "$lang" in
                zh-CN) s="fzf 已安装" ;; zh-TW) s="fzf 已安裝" ;;
                ja)    s="fzf はインストール済みです" ;; ko)    s="fzf 이미 설치됨" ;;
                *)     s="fzf is already installed" ;;
            esac ;;
        msg.zsh_installed)
            case "$lang" in
                zh-CN) s="Zsh 已安装：%s" ;; zh-TW) s="Zsh 已安裝：%s" ;;
                ja)    s="Zsh はインストール済み: %s" ;; ko)    s="Zsh 설치됨: %s" ;;
                *)     s="Zsh is installed: %s" ;;
            esac ;;
        msg.zinit_installed)
            case "$lang" in
                zh-CN) s="Zinit 已安装于 %s" ;; zh-TW) s="Zinit 已安裝於 %s" ;;
                ja)    s="Zinit は %s にインストール済み" ;; ko)    s="Zinit 설치 위치: %s" ;;
                *)     s="Zinit is installed at %s" ;;
            esac ;;
        opt.title)
            case "$lang" in
                zh-CN) s="可选组件与设置 —— 每个回答都会写进 ~/.zshrc：" ;;
                zh-TW) s="可選元件與設定 —— 每個回答都會寫進 ~/.zshrc：" ;;
                ja)    s="オプションのコンポーネントと設定 — 回答は ~/.zshrc に書き込まれます:" ;;
                ko)    s="선택 구성 요소 및 설정 — 각 응답은 ~/.zshrc 에 기록됩니다:" ;;
                *)     s="Optional components & settings — each answer is written into ~/.zshrc:" ;;
            esac ;;
        opt.menu)
            case "$lang" in
                zh-CN) s="实时弹窗：打字即列出候选（无需按 Tab）？" ;;
                zh-TW) s="即時彈窗：打字即列出候選（無需按 Tab）？" ;;
                ja)    s="入力中ポップアップ：Tab を押さずに候補を一覧表示しますか？" ;;
                ko)    s="입력 중 팝업: Tab 없이 후보를 실시간 표시할까요?" ;;
                *)     s="Type-to-popup: list completion candidates as you type (no Tab)?" ;;
            esac ;;
        opt.single_column)
            case "$lang" in
                zh-CN) s="该弹窗改成单列多行（每行一个候选）？注意：单列由插件自己生成候选，会失去描述 / 着色 / 模糊匹配，覆盖不到的场景（git 子命令、ssh 主机、--选项）仍会变回网格。默认否。" ;;
                zh-TW) s="該彈窗改成單列多行（每行一個候選）？注意：單列由外掛自行產生候選，會失去描述 / 著色 / 模糊匹配，涵蓋不到的場景（git 子指令、ssh 主機、--選項）仍會回到網格。預設否。" ;;
                ja)    s="ポップアップを単一列（1 行 1 候補）にしますか？注意: 単一列はプラグインが独自に生成した候補のため、説明・色・あいまい一致が失われ、生成できない文脈（git サブコマンド、ssh ホスト、--オプション）はグリッドに戻ります。既定はいいえ。" ;;
                ko)    s="팝업을 단일 열(한 줄에 하나)로 바꿀까요? 주의: 단일 열은 플러그인이 직접 생성한 후보라 설명 / 색 / 퍼지 매칭이 사라지고, 생성하지 못하는 맥락(git 하위 명령, ssh 호스트, --옵션)은 다시 그리드로 돌아갑니다. 기본값은 아니오." ;;
                *)     s="Draw that popup as a SINGLE COLUMN (one candidate per line)? NOTE: the column is GENERATED by the plugin, so descriptions / colours / fuzzy matching are lost for those contexts, and anything it cannot generate (git subcommands, ssh hosts, --options) falls back to the grid. Default: no." ;;
            esac ;;
        opt.recent_paths)
            case "$lang" in
                zh-CN) s="输入 cd 加空格时列出最近访问过的目录？" ;;
                zh-TW) s="輸入 cd 加空格時列出最近造訪過的目錄？" ;;
                ja)    s="cd と入力したときに最近のディレクトリを一覧表示しますか？" ;;
                ko)    s="cd 입력 시 최근 디렉터리를 표시할까요?" ;;
                *)     s="List recently-used directories when you type cd and a space?" ;;
            esac ;;
        opt.history_keys)
            case "$lang" in
                zh-CN) s="把上下箭头改成按前缀搜索历史（仅在有输入时）？关闭则保留原生历史导航。" ;;
                zh-TW) s="把上下箭頭改成按前綴搜尋歷史（僅在有輸入時）？關閉則保留原生歷史導覽。" ;;
                ja)    s="上下キーを前方一致の履歴検索に割り当てますか？オフなら標準の履歴移動。" ;;
                ko)    s="위아래 화살표를 접두어 기준 기록 검색으로 바꿀까요? 끄면 기본 기록 탐색." ;;
                *)     s="Rebind Up/Down to prefix-search history while the line is non-empty? (off = native history)" ;;
            esac ;;
        opt.native_menu)
            case "$lang" in
                zh-CN) s="让 Tab 打开可上下选择的菜单（SMART_NATIVE_MENU_SELECT）？" ;;
                zh-TW) s="讓 Tab 開啟可上下選擇的選單（SMART_NATIVE_MENU_SELECT）？" ;;
                ja)    s="Tab で選択可能なメニューを開きますか（SMART_NATIVE_MENU_SELECT）？" ;;
                ko)    s="Tab 으로 선택 가능한 메뉴를 열까요? (SMART_NATIVE_MENU_SELECT)" ;;
                *)     s="Make Tab open a selectable menu (SMART_NATIVE_MENU_SELECT)?" ;;
            esac ;;
        opt.fzf_tab)
            # This is the "two boxes at once" question, so it is phrased as a
            # CHOICE between two listers rather than as an extra feature: both
            # are entitled to draw, and picking this one turns ours off
            # (SMART_MENU_LISTER=fzf-tab) so only one list can ever appear.
            case "$lang" in
                zh-CN) s="列表由谁画？选“是”= 交给 fzf-tab 的浮动框（本插件的候选列表会关闭）；选“否”= 用本插件内置的列表。" ;;
                zh-TW) s="清單由誰畫？選「是」= 交給 fzf-tab 的浮動框（本外掛的候選清單會關閉）；選「否」= 用本外掛內建的清單。" ;;
                ja)    s="一覧を描くのはどちらにしますか？ 「はい」= fzf-tab のフローティング一覧（当プラグインの一覧は停止）／「いいえ」= 当プラグイン内蔵の一覧。" ;;
                ko)    s="목록을 누가 그릴까요? \"예\" = fzf-tab 의 부동 목록(이 플러그인의 목록은 꺼짐), \"아니오\" = 이 플러그인의 내장 목록." ;;
                *)     s="WHO draws the candidate list?  Yes = fzf-tab's floating picker (this plugin's own list is turned off).  No = this plugin's built-in list." ;;
            esac ;;
        opt.fzf_warn)
            case "$lang" in
                zh-CN) s="注意：fzf-tab 是第二个补全列表器——两者同时开启会出现两个弹窗，所以默认关闭。" ;;
                zh-TW) s="注意：fzf-tab 是第二個補全列表器——兩者同時開啟會出現兩個彈窗，因此預設關閉。" ;;
                ja)    s="注意: fzf-tab は 2 つ目の補完リスト表示器です。両方有効だとポップアップが 2 つ出ます。既定はオフ。" ;;
                ko)    s="주의: fzf-tab 은 두 번째 완성 목록 표시기입니다. 둘 다 켜면 팝업이 두 개 뜨므로 기본값은 꺼짐입니다." ;;
                *)     s="NOTE: fzf-tab is a SECOND completion lister — with it on, two popups can appear at once. Default is OFF on purpose." ;;
            esac ;;
        opt.vimode)
            case "$lang" in
                zh-CN) s="同时安装 zsh-vi-mode（命令行的 vi 按键）？" ;;
                zh-TW) s="同時安裝 zsh-vi-mode（命令列的 vi 按鍵）？" ;;
                ja)    s="zsh-vi-mode（コマンドラインの vi キーバインド）も導入しますか？" ;;
                ko)    s="zsh-vi-mode (명령줄 vi 키 바인딩)도 설치할까요?" ;;
                *)     s="Also install zsh-vi-mode (vi keybindings for the command line)?" ;;
            esac ;;
        opt.strategy_prompt)
            case "$lang" in
                zh-CN) s="行内灰色建议取自哪里？" ;;
                zh-TW) s="行內灰色建議取自哪裡？" ;;
                ja)    s="インラインのグレー提案の取得元は？" ;;
                ko)    s="인라인 회색 제안의 출처는?" ;;
                *)     s="Where should the inline grey suggestion come from?" ;;
            esac ;;
        opt.strategy_history)
            case "$lang" in
                zh-CN) s="仅历史记录" ;; zh-TW) s="僅歷史記錄" ;;
                ja)    s="履歴のみ" ;;  ko)    s="기록만" ;;
                *)     s="history only" ;;
            esac ;;
        opt.strategy_completion)
            case "$lang" in
                zh-CN) s="仅补全系统" ;; zh-TW) s="僅補全系統" ;;
                ja)    s="補完のみ" ;;     ko)    s="완성만" ;;
                *)     s="completion only" ;;
            esac ;;
        opt.strategy_both)
            case "$lang" in
                zh-CN) s="先历史、后补全（推荐，路径输一半也有提示）" ;; zh-TW) s="先歷史、後補全（推薦，路徑輸一半也有提示）" ;;
                ja)    s="履歴のち補完（推奨。パス入力の途中でも提案が出る）" ;;   ko)    s="기록 후 완성 (권장, 경로 입력 중에도 제안 표시)" ;;
                *)     s="history, then completion (recommended: hints even halfway through a path)" ;;
            esac ;;
            q.upgrade)
                case "$lang" in
                    zh-CN) s="检查组件升级？" ;; zh-TW) s="檢查元件升級？" ;;
                    ja)    s="コンポーネントの更新を確認しますか？" ;;
                    ko)    s="구성 요소 업데이트를 확인할까요?" ;;
                    *)     s="Check for upgrades?" ;;
                esac ;;
            i.reinstalling_zsh)
                case "$lang" in
                    zh-CN) s="正在重新安装 zsh …" ;; zh-TW) s="正在重新安裝 zsh …" ;;
                    ja)    s="zsh を再インストール中 …" ;;
                    ko)    s="zsh 재설치 중 ..." ;;
                    *)     s="Reinstalling zsh ..." ;;
                esac ;;
            s.zsh_reinstalled)
                case "$lang" in
                    zh-CN) s="zsh 已重装" ;; zh-TW) s="zsh 已重裝" ;;
                    ja)    s="zsh を再インストールしました" ;;
                    ko)    s="zsh 재설치 완료" ;;
                    *)     s="Zsh reinstalled" ;;
                esac ;;
            w.zsh_reinstall_failed)
                case "$lang" in
                    zh-CN) s="zsh 重装失败" ;; zh-TW) s="zsh 重裝失敗" ;;
                    ja)    s="zsh の再インストールに失敗しました" ;;
                    ko)    s="zsh 재설치 실패" ;;
                    *)     s="Zsh reinstall failed" ;;
                esac ;;
            w.homebrew_missing)
                case "$lang" in
                    zh-CN) s="未找到 Homebrew，跳过升级" ;; zh-TW) s="未找到 Homebrew，跳過升級" ;;
                    ja)    s="Homebrew が見つからないため更新をスキップします" ;;
                    ko)    s="Homebrew가 없어 업데이트를 건너뜁니다" ;;
                    *)     s="Homebrew missing, skipping upgrade" ;;
                esac ;;
            e.homebrew_not_found)
                case "$lang" in
                    zh-CN) s="未找到 Homebrew。请先安装：%s" ;; zh-TW) s="未找到 Homebrew。請先安裝：%s" ;;
                    ja)    s="Homebrew が見つかりません。先にインストールしてください: %s" ;;
                    ko)    s="Homebrew를 찾을 수 없습니다. 먼저 설치하세요: %s" ;;
                    *)     s="Homebrew not found. Please install first: %s" ;;
                esac ;;
            s.starship_present)
                case "$lang" in
                    zh-CN) s="Starship 已安装：%s" ;; zh-TW) s="Starship 已安裝：%s" ;;
                    ja)    s="Starship はインストール済み: %s" ;;
                    ko)    s="Starship 설치됨: %s" ;;
                    *)     s="Starship is installed: %s" ;;
                esac ;;
            w.starship_upgrade_failed)
                case "$lang" in
                    zh-CN) s="Starship 升级失败（不影响继续）" ;; zh-TW) s="Starship 升級失敗（不影響繼續）" ;;
                    ja)    s="Starship の更新に失敗しました（続行に影響なし）" ;;
                    ko)    s="Starship 업데이트 실패(치명적이지 않음)" ;;
                    *)     s="Starship upgrade failed (non-fatal)" ;;
                esac ;;
            s.starship_installed)
                case "$lang" in
                    zh-CN) s="Starship 已安装" ;; zh-TW) s="Starship 已安裝" ;;
                    ja)    s="Starship をインストールしました" ;;
                    ko)    s="Starship 설치 완료" ;;
                    *)     s="Starship installed" ;;
                esac ;;
            s.atuin_installed)
                case "$lang" in
                    zh-CN) s="Atuin 已安装" ;; zh-TW) s="Atuin 已安裝" ;;
                    ja)    s="Atuin をインストールしました" ;;
                    ko)    s="Atuin 설치 완료" ;;
                    *)     s="Atuin installed" ;;
                esac ;;
            s.zinit_installed)
                case "$lang" in
                    zh-CN) s="Zinit 已安装" ;; zh-TW) s="Zinit 已安裝" ;;
                    ja)    s="Zinit をインストールしました" ;;
                    ko)    s="Zinit 설치 완료" ;;
                    *)     s="Zinit installed" ;;
                esac ;;
            e.zinit_clone_failed)
                case "$lang" in
                    zh-CN) s="Zinit 克隆失败。请检查网络连接。" ;; zh-TW) s="Zinit 複製失敗。請檢查網路連線。" ;;
                    ja)    s="Zinit のクローンに失敗しました。ネットワーク接続を確認してください。" ;;
                    ko)    s="Zinit 복제 실패. 네트워크 연결을 확인하세요." ;;
                    *)     s="Zinit clone failed. Check your internet connection." ;;
                esac ;;
            i.cloning_plugin)
                case "$lang" in
                    zh-CN) s="正在克隆 zsh-smart-complete 插件仓库 …" ;; zh-TW) s="正在複製 zsh-smart-complete 外掛儲存庫 …" ;;
                    ja)    s="zsh-smart-complete プラグインのリポジトリをクローン中 …" ;;
                    ko)    s="zsh-smart-complete 플러그인 저장소 복제 중 ..." ;;
                    *)     s="Cloning zsh-smart-complete plugin repo ..." ;;
                esac ;;
            w.plugin_clone_failed)
                case "$lang" in
                    zh-CN) s="zsh-smart-complete 克隆失败。若使用 Zinit，zinit light 会自动克隆。" ;; zh-TW) s="zsh-smart-complete 複製失敗。若使用 Zinit，zinit light 會自動複製。" ;;
                    ja)    s="zsh-smart-complete のクローンに失敗しました。Zinit を使っている場合、zinit light が自動的にクローンします。" ;;
                    ko)    s="zsh-smart-complete 복제 실패. Zinit 사용 시 zinit light가 자동으로 복제합니다." ;;
                    *)     s="zsh-smart-complete clone failed. If running Zinit, zinit light will clone it automatically." ;;
                esac ;;
            s.fzf_already)
                case "$lang" in
                    zh-CN) s="fzf 已安装" ;; zh-TW) s="fzf 已安裝" ;;
                    ja)    s="fzf はインストール済みです" ;;
                    ko)    s="fzf가 이미 설치되어 있습니다" ;;
                    *)     s="fzf is already installed" ;;
                esac ;;
            s.backed_up)
                case "$lang" in
                    zh-CN) s="已备份：%s" ;; zh-TW) s="已備份：%s" ;;
                    ja)    s="バックアップしました: %s" ;;
                    ko)    s="백업 완료: %s" ;;
                    *)     s="Backed up: %s" ;;
                esac ;;
            s.removed_cascaded_backup)
                case "$lang" in
                    zh-CN) s="已删除级联备份：%s" ;; zh-TW) s="已刪除級聯備份：%s" ;;
                    ja)    s="連鎖バックアップを削除しました: %s" ;;
                    ko)    s="연쇄 백업 제거: %s" ;;
                    *)     s="Removed cascaded backup: %s" ;;
                esac ;;
            s.removed_backup)
                case "$lang" in
                    zh-CN) s="已删除备份：%s" ;; zh-TW) s="已刪除備份：%s" ;;
                    ja)    s="バックアップを削除しました: %s" ;;
                    ko)    s="백업 제거: %s" ;;
                    *)     s="Removed backup: %s" ;;
                esac ;;
            s.removed_bak_dir)
                case "$lang" in
                    zh-CN) s="已删除插件备份目录：%s" ;; zh-TW) s="已刪除外掛備份目錄：%s" ;;
                    ja)    s="プラグインバックアップディレクトリを削除しました: %s" ;;
                    ko)    s="플러그인 백업 디렉터리 제거: %s" ;;
                    *)     s="Removed plugin bak dir: %s" ;;
                esac ;;
            i.backup_cleanup_done)
                case "$lang" in
                    zh-CN) s="备份清理完成。" ;; zh-TW) s="備份清理完成。" ;;
                    ja)    s="バックアップの整理が完了しました。" ;;
                    ko)    s="백업 정리 완료." ;;
                    *)     s="Backup cleanup done." ;;
                esac ;;
            w.conflict_plugin_dir)
                case "$lang" in
                    zh-CN) s="发现冲突插件目录：%s" ;; zh-TW) s="發現衝突外掛目錄：%s" ;;
                    ja)    s="競合するプラグインディレクトリを検出: %s" ;;
                    ko)    s="충돌하는 플러그인 디렉터리 발견: %s" ;;
                    *)     s="Found conflict plugin dir: %s" ;;
                esac ;;
            i.generating_starship)
                case "$lang" in
                    zh-CN) s="正在生成 %s（推荐模板）…" ;; zh-TW) s="正在生成 %s（推薦範本）…" ;;
                    ja)    s="%s を生成中（推奨テンプレート）…" ;;
                    ko)    s="%s 생성 중(권장 템플릿) ..." ;;
                    *)     s="Generating %s (recommended template)..." ;;
                esac ;;
            s.starship_cfg_installed)
                case "$lang" in
                    zh-CN) s="Starship 配置已安装" ;; zh-TW) s="Starship 設定已安裝" ;;
                    ja)    s="Starship 設定をインストールしました" ;;
                    ko)    s="Starship 설정 설치 완료" ;;
                    *)     s="Starship config installed" ;;
                esac ;;
            w.starship_cfg_exists)
                case "$lang" in
                    zh-CN) s="Starship 配置已存在：%s" ;; zh-TW) s="Starship 設定已存在：%s" ;;
                    ja)    s="Starship 設定が既に存在します: %s" ;;
                    ko)    s="Starship 설정이 이미 있음: %s" ;;
                    *)     s="Starship config exists: %s" ;;
                esac ;;
            q.overwrite_starship)
                case "$lang" in
                    zh-CN) s="用推荐模板覆盖？" ;; zh-TW) s="用推薦範本覆蓋？" ;;
                    ja)    s="推奨テンプレートで上書きしますか？" ;;
                    ko)    s="권장 템플릿으로 덮어쓸까요?" ;;
                    *)     s="Overwrite with recommended template?" ;;
                esac ;;
            s.starship_cfg_updated)
                case "$lang" in
                    zh-CN) s="Starship 配置已更新（备份保留在 .bak.*）" ;; zh-TW) s="Starship 設定已更新（備份保留在 .bak.*）" ;;
                    ja)    s="Starship 設定を更新しました（バックアップは .bak.* に保持）" ;;
                    ko)    s="Starship 설정 업데이트 완료(백업은 .bak.* 에 유지)" ;;
                    *)     s="Starship config updated (backup kept at .bak.*)" ;;
                esac ;;
            q.del_omz)
                case "$lang" in
                    zh-CN) s="删除 ~/.oh-my-zsh 目录（备份为 .bak）？" ;; zh-TW) s="刪除 ~/.oh-my-zsh 目錄（備份為 .bak）？" ;;
                    ja)    s="~/.oh-my-zsh ディレクトリを削除しますか（.bak としてバックアップ）？" ;;
                    ko)    s="~/.oh-my-zsh 디렉터리를 삭제할까요(.bak 백업)?" ;;
                    *)     s="Delete ~/.oh-my-zsh directory (backed up as .bak)?" ;;
                esac ;;
            q.del_zinit_omz)
                case "$lang" in
                    zh-CN) s="删除 zinit 的 OMZ 目录 %s（已备份）？" ;; zh-TW) s="刪除 zinit 的 OMZ 目錄 %s（已備份）？" ;;
                    ja)    s="zinit の OMZ ディレクトリ %s を削除しますか（バックアップ済み）？" ;;
                    ko)    s="zinit OMZ 디렉터리 %s을(를) 삭제할까요(백업됨)?" ;;
                    *)     s="Delete zinit OMZ dir %s (backed up)?" ;;
                esac ;;
            q.del_p10k)
                case "$lang" in
                    zh-CN) s="删除 ~/.p10k.zsh（已备份）？" ;; zh-TW) s="刪除 ~/.p10k.zsh（已備份）？" ;;
                    ja)    s="~/.p10k.zsh を削除しますか（バックアップ済み）？" ;;
                    ko)    s="~/.p10k.zsh을(를) 삭제할까요(백업됨)?" ;;
                    *)     s="Delete ~/.p10k.zsh (backed up)?" ;;
                esac ;;
            q.del_p10k_dir)
                case "$lang" in
                    zh-CN) s="删除 ~/.powerlevel10k 目录（已备份）？" ;; zh-TW) s="刪除 ~/.powerlevel10k 目錄（已備份）？" ;;
                    ja)    s="~/.powerlevel10k ディレクトリを削除しますか（バックアップ済み）？" ;;
                    ko)    s="~/.powerlevel10k 디렉터리를 삭제할까요(백업됨)?" ;;
                    *)     s="Delete ~/.powerlevel10k directory (backed up)?" ;;
                esac ;;
            q.del_zinit_p10k)
                case "$lang" in
                    zh-CN) s="删除 zinit 插件目录 %s（已备份）？" ;; zh-TW) s="刪除 zinit 外掛目錄 %s（已備份）？" ;;
                    ja)    s="zinit プラグインディレクトリ %s を削除しますか（バックアップ済み）？" ;;
                    ko)    s="zinit 플러그인 디렉터리 %s을(를) 삭제할까요(백업됨)?" ;;
                    *)     s="Delete zinit plugin dir %s (backed up)?" ;;
                esac ;;
            i.installing_vimode)
                case "$lang" in
                    zh-CN) s="正在安装 zsh-vi-mode（Zinit 插件）…" ;; zh-TW) s="正在安裝 zsh-vi-mode（Zinit 外掛）…" ;;
                    ja)    s="zsh-vi-mode をインストール中（Zinit プラグイン）…" ;;
                    ko)    s="zsh-vi-mode 설치 중(Zinit 플러그인) ..." ;;
                    *)     s="Installing zsh-vi-mode (Zinit plugin) ..." ;;
                esac ;;
            i.installing_fzftab)
                case "$lang" in
                    zh-CN) s="正在安装 fzf-tab（Zinit 插件）…" ;; zh-TW) s="正在安裝 fzf-tab（Zinit 外掛）…" ;;
                    ja)    s="fzf-tab をインストール中（Zinit プラグイン）…" ;;
                    ko)    s="fzf-tab 설치 중(Zinit 플러그인) ..." ;;
                    *)     s="Installing fzf-tab (Zinit plugin) ..." ;;
                esac ;;
            w.fzftab_needs_fzf)
                case "$lang" in
                    zh-CN) s="fzf-tab 需要 fzf 可执行文件，但 PATH 中没有——请先安装（brew install fzf / apt install fzf），否则 fzf-tab 不会生效。" ;; zh-TW) s="fzf-tab 需要 fzf 執行檔，但 PATH 中沒有——請先安裝（brew install fzf / apt install fzf），否則 fzf-tab 不會生效。" ;;
                    ja)    s="fzf-tab には fzf バイナリが必要ですが PATH にありません — 先にインストールしてください（brew install fzf / apt install fzf）。なければ fzf-tab は何もしません。" ;;
                    ko)    s="fzf-tab에는 fzf 바이너리가 필요하지만 PATH에 없습니다 — 먼저 설치하세요(brew install fzf / apt install fzf). 그렇지 않으면 fzf-tab은 아무 것도 하지 않습니다." ;;
                    *)     s="fzf-tab needs the 'fzf' binary and it is not on PATH — install it (brew install fzf / apt install fzf) or fzf-tab will do nothing." ;;
                esac ;;
            i.no_zshrc_found)
                case "$lang" in
                    zh-CN) s="未找到 ~/.zshrc——正在创建包含 zsh-smart-complete 块的最小配置 …" ;; zh-TW) s="未找到 ~/.zshrc——正在建立包含 zsh-smart-complete 區塊的最小設定 …" ;;
                    ja)    s="~/.zshrc が見つからないため、zsh-smart-complete ブロック込みの最小構成を作成中 …" ;;
                    ko)    s="~/.zshrc를 찾을 수 없어 zsh-smart-complete 블록을 포함한 최소 설정을 생성 중 ..." ;;
                    *)     s="No ~/.zshrc found — creating a minimal one with the zsh-smart-complete block ..." ;;
                esac ;;
            s.zshrc_created)
                case "$lang" in
                    zh-CN) s="已创建包含 zsh-smart-complete 集成块的 .zshrc" ;; zh-TW) s="已建立包含 zsh-smart-complete 整合區塊的 .zshrc" ;;
                    ja)    s="zsh-smart-complete 統合ブロック入りの .zshrc を作成しました" ;;
                    ko)    s="zsh-smart-complete 통합 블록이 포함된 .zshrc 생성 완료" ;;
                    *)     s=".zshrc created with the zsh-smart-complete integration block" ;;
                esac ;;
            i.zshrc_has_block)
                case "$lang" in
                    zh-CN) s=".zshrc 已包含 zsh-smart-complete 块" ;; zh-TW) s=".zshrc 已包含 zsh-smart-complete 區塊" ;;
                    ja)    s=".zshrc には既に zsh-smart-complete ブロックがあります" ;;
                    ko)    s=".zshrc에 이미 zsh-smart-complete 블록이 있습니다" ;;
                    *)     s=".zshrc already has a zsh-smart-complete block" ;;
                esac ;;
            s.zshrc_replaced)
                case "$lang" in
                    zh-CN) s=".zshrc 已替换为推荐的全栈模板（备份保留在 .bak.*）" ;; zh-TW) s=".zshrc 已替換為推薦的全端範本（備份保留在 .bak.*）" ;;
                    ja)    s=".zshrc を推奨フルスタックテンプレートで置き換えました（バックアップは .bak.*）" ;;
                    ko)    s=".zshrc를 권장 풀스택 템플릿으로 교체했습니다(백업은 .bak.*)" ;;
                    *)     s=".zshrc replaced with the recommended full-stack template (backup kept at .bak.*)" ;;
                esac ;;
            s.zshrc_updated)
                case "$lang" in
                    zh-CN) s=".zshrc 已更新集成块（备份保留在 .bak.*）" ;; zh-TW) s=".zshrc 已更新整合區塊（備份保留在 .bak.*）" ;;
                    ja)    s=".zshrc に統合ブロックを反映しました（バックアップは .bak.*）" ;;
                    ko)    s=".zshrc에 통합 블록을 적용했습니다(백업은 .bak.*)" ;;
                    *)     s=".zshrc updated with the integration block (backup kept at .bak.*)" ;;
                esac ;;
            i.zshrc_untouched)
                case "$lang" in
                    zh-CN) s="未写入 ~/.zshrc（你两次都拒绝了）——以上选项未生效。" ;; zh-TW) s="未寫入 ~/.zshrc（你兩次都拒絕了）——以上選項未生效。" ;;
                    ja)    s="~/.zshrc には何も書き込んでいません（両方とも辞退）——上記のオプションは未適用です。" ;;
                    ko)    s="~/.zshrc에 기록하지 않았습니다(둘 다 거부) — 위 옵션은 적용되지 않았습니다." ;;
                    *)     s="Nothing written to ~/.zshrc (you declined both) — the options above were not applied." ;;
                esac ;;
            i.plugin_only)
                case "$lang" in
                    zh-CN) s="仅插件安装——只管理 ~/.zshrc 中的 zsh-smart-complete 块" ;; zh-TW) s="僅外掛安裝——只管理 ~/.zshrc 中的 zsh-smart-complete 區塊" ;;
                    ja)    s="プラグインのみインストール — ~/.zshrc の zsh-smart-complete ブロックのみ管理します" ;;
                    ko)    s="플러그인만 설치 — ~/.zshrc의 zsh-smart-complete 블록만 관리합니다" ;;
                    *)     s="Plugin-only install — managing only the zsh-smart-complete block in ~/.zshrc" ;;
                esac ;;
            s.zshrc_block_refreshed)
                case "$lang" in
                    zh-CN) s=".zshrc 的 zsh-smart-complete 块已刷新（备份保留在 .bak.*）" ;; zh-TW) s=".zshrc 的 zsh-smart-complete 區塊已重新整理（備份保留在 .bak.*）" ;;
                    ja)    s=".zshrc の zsh-smart-complete ブロックを更新しました（バックアップは .bak.*）" ;;
                    ko)    s=".zshrc의 zsh-smart-complete 블록을 갱신했습니다(백업은 .bak.*)" ;;
                    *)     s=".zshrc zsh-smart-complete block refreshed (backup kept at .bak.*)" ;;
                esac ;;
            i.zshrc_already_present)
                case "$lang" in
                    zh-CN) s="~/.zshrc 中已存在 zsh-smart-complete 配置——保持不变。" ;; zh-TW) s="~/.zshrc 中已存在 zsh-smart-complete 設定——保持不變。" ;;
                    ja)    s="~/.zshrc に zsh-smart-complete の設定が既にあります — 変更しません。" ;;
                    ko)    s="~/.zshrc에 zsh-smart-complete 설정이 이미 있습니다 — 변경하지 않습니다." ;;
                    *)     s="zsh-smart-complete config already present in ~/.zshrc — left unchanged." ;;
                esac ;;
            s.settings_created)
                case "$lang" in
                    zh-CN) s="本地设置文件已创建于 %s。运行 \`zsc-settings\`（若已安装）或直接编辑该文件，然后重启 zsh 生效。" ;;
                    zh-TW) s="本地設定檔已建立於 %s。執行 \`zsc-settings\`（若已安裝）或直接編輯該檔案，然後重啟 zsh 生效。" ;;
                    ja)    s="ローカル設定ファイルを %s に作成しました。\`zsc-settings\`（導入済みの場合）を実行するか、直接編集し、その後 zsh を再起動して反映してください。" ;;
                    ko)    s="로컬 설정 파일을 %s 에 생성했습니다. \`zsc-settings\`(설치된 경우)를 실행하거나 파일을 직접 편집한 뒤 zsh 를 재시작하세요." ;;
                    *)     s="Local settings file created at %s. Run \`zsc-settings\` (if installed) or edit the file directly, then restart zsh to apply." ;;
                esac ;;
            s.settings_symlink)
                case "$lang" in
                    zh-CN) s="已软链 \`zsc-settings\` -> %s" ;;
                    zh-TW) s="已軟鏈 \`zsc-settings\` -> %s" ;;
                    ja)    s="シンボリックリンクしました \`zsc-settings\` -> %s" ;;
                    ko)    s="심볼릭 링크했습니다 \`zsc-settings\` -> %s" ;;
                    *)     s="Symlinked \`zsc-settings\` -> %s" ;;
                esac ;;
            s.installer_finished)
                case "$lang" in
                    zh-CN) s="zsh-smart-complete 安装完成" ;; zh-TW) s="zsh-smart-complete 安裝完成" ;;
                    ja)    s="zsh-smart-complete のインストールが完了しました" ;;
                    ko)    s="zsh-smart-complete 설치가 완료되었습니다" ;;
                    *)     s="zsh-smart-complete installer finished" ;;
                esac ;;
            i.reload_hint)
                case "$lang" in
                    zh-CN) s="让新配置生效，请运行：" ;; zh-TW) s="讓新設定生效，請執行：" ;;
                    ja)    s="新しい設定を反映するには実行してください:" ;;
                    ko)    s="새 설정을 적용하려면 실행하세요:" ;;
                    *)     s="To reload with the new config, run:" ;;
                esac ;;
            i.try_hint)
                case "$lang" in
                    zh-CN) s="然后试试：" ;; zh-TW) s="然後試試：" ;;
                    ja)    s="それから試してみてください:" ;;
                    ko)    s="그다음 시도해 보세요:" ;;
                    *)     s="Then try:" ;;
                esac ;;
            i.hint_tab)
                case "$lang" in
                    zh-CN) s="git s  [Tab]   → 原生补全（菜单）" ;; zh-TW) s="git s  [Tab]   → 原生補全（選單）" ;;
                    ja)    s="git s  [Tab]   → ネイティブ補完（メニュー）" ;;
                    ko)    s="git s  [Tab]   → 네이티브 완성(메뉴)" ;;
                    *)     s="git s  [Tab]   → native completion (menu)" ;;
                esac ;;
            i.hint_right)
                case "$lang" in
                    zh-CN) s="git s  [→]     → 接受行内建议" ;; zh-TW) s="git s  [→]     → 接受行內建議" ;;
                    ja)    s="git s  [→]     → インライン提案を確定" ;;
                    ko)    s="git s  [→]     → 인라인 제안 수락" ;;
                    *)     s="git s  [→]     → inline suggestion accept" ;;
                esac ;;
            i.hint_up)
                case "$lang" in
                    zh-CN) s="git s  [↑]     → 原生历史翻阅" ;; zh-TW) s="git s  [↑]     → 原生歷史翻閱" ;;
                    ja)    s="git s  [↑]     → ネイティブ履歴移動" ;;
                    ko)    s="git s  [↑]     → 네이티브 히스토리 탐색" ;;
                    *)     s="git s  [↑]     → native history navigation" ;;
                esac ;;
            q.install_fzf)
                case "$lang" in
                    zh-CN) s="安装 fzf（可选，更好的历史界面）？" ;; zh-TW) s="安裝 fzf（可選，更好的歷史介面）？" ;;
                    ja)    s="fzf をインストールしますか（任意・より良い履歴 UI）？" ;;
                    ko)    s="fzf를 설치할까요(선택, 더 나은 히스토리 UI)?" ;;
                    *)     s="Install fzf (optional, nicer history UI)?" ;;
                esac ;;
            q.append_block)
                case "$lang" in
                    zh-CN) s="把 zsh-smart-complete 加载块追加到 ~/.zshrc？" ;; zh-TW) s="把 zsh-smart-complete 載入區塊附加到 ~/.zshrc？" ;;
                    ja)    s="zsh-smart-complete ローダーブロックを ~/.zshrc に追加しますか？" ;;
                    ko)    s="~/.zshrc에 zsh-smart-complete 로더 블록을 추가할까요?" ;;
                    *)     s="Append zsh-smart-complete loader block to ~/.zshrc?" ;;
                esac ;;
            s.starship_cfg_written)
                case "$lang" in
                    zh-CN) s="Starship 配置已写入 %s" ;; zh-TW) s="Starship 設定已寫入 %s" ;;
                    ja)    s="Starship 設定を %s に書き込みました" ;;
                    ko)    s="Starship 설정을 %s에 기록했습니다" ;;
                    *)     s="Starship config written to %s" ;;
                esac ;;
            w.entware_clone_failed)
                case "$lang" in
                    zh-CN) s="克隆失败；若已安装 Zinit，zinit light 会自动获取。" ;; zh-TW) s="複製失敗；若已安裝 Zinit，zinit light 會自動取得。" ;;
                    ja)    s="クローンに失敗しました。Zinit が入っていれば zinit light が自動的に取得します。" ;;
                    ko)    s="복제 실패; Zinit이 설치되어 있으면 zinit light가 자동으로 가져옵니다." ;;
                    *)     s="clone failed; 'zinit light' will fetch it automatically if Zinit is installed." ;;
                esac ;;
            w.atuin_failed_entware)
                case "$lang" in
                    zh-CN) s="Atuin 安装失败（不影响继续）。参见 https://atuin.sh ——若 ~/.zshrc 下方块存在即会启用。" ;; zh-TW) s="Atuin 安裝失敗（不影響繼續）。參見 https://atuin.sh ——若 ~/.zshrc 下方塊存在即會啟用。" ;;
                    ja)    s="Atuin のインストールに失敗しました（続行に影響なし）。https://atuin.sh 参照 — 下の ~/.zshrc ブロックがあれば有効になります。" ;;
                    ko)    s="Atuin 설치 실패(치명적이지 않음). https://atuin.sh 참조 — 아래 ~/.zshrc 블록이 있으면 활성화됩니다." ;;
                    *)     s="Atuin install failed (non-fatal). See https://atuin.sh — the ~/.zshrc block below enables it if present." ;;
                esac ;;
            i.starship_cfg_ok)
                case "$lang" in
                    zh-CN) s="%s 已经是推荐的 Starship 布局，保持不变。" ;; zh-TW) s="%s 已經是推薦的 Starship 佈局，保持不變。" ;;
                    ja)    s="%s は推奨レイアウト済みです。そのままにします。" ;; ko)    s="%s 이미 권장 Starship 레이아웃입니다. 그대로 둡니다." ;;
                    *)     s="%s already uses the recommended Starship layout - left as-is." ;;
                esac ;;
            w.starship_cfg_legacy)
                case "$lang" in
                    zh-CN) s="%s 里没有 format 行，Starship 正在用自带的默认布局。已替换为推荐的两行提示符，旧文件已备份。" ;; zh-TW) s="%s 裡沒有 format 行，Starship 正在用自帶的預設佈局。已替換為推薦的兩行提示符，舊檔案已備份。" ;;
                    ja)    s="%s に format 行が無いため、Starship は既定レイアウトを描画しています。推奨の 2 行プロンプトに置き換えました（元ファイルはバックアップ済み）。" ;; ko)    s="%s 에 format 줄이 없어 Starship가 기본 레이아웃을 그리고 있습니다. 권장 2줄 프롬프트로 교체했습니다(원본 백업 완료)." ;;
                    *)     s="%s has no format key, so Starship is rendering its own default layout. Replaced with the recommended two-line prompt; the old file was backed up." ;;
                esac ;;
            s.starship_cfg_repaired)
                case "$lang" in
                    zh-CN) s="Starship 配置已修复并写入 %s" ;; zh-TW) s="Starship 設定已修復並寫入 %s" ;;
                    ja)    s="Starship 設定を修復して %s に書き込みました" ;; ko)    s="Starship 설정을 수정하여 %s 에 기록했습니다" ;;
                    *)     s="Starship config repaired and written to %s" ;;
                esac ;;
            e.opkg_missing_zsh)
                case "$lang" in
                    zh-CN) s="未找到 opkg，无法自动安装 Zsh。请先配置 Entware/opkg 后重试。" ;; zh-TW) s="未找到 opkg，無法自動安裝 Zsh。請先設定 Entware/opkg 後重試。" ;;
                    ja)    s="opkg が見つからず、Zsh を自動インストールできません。先に Entware/opkg を設定して再試行してください。" ;; ko)    s="opkg를 찾을 수 없어 Zsh을 자동 설치할 수 없습니다. 먼저 Entware/opkg를 설정하고 재시도하세요." ;;
                    *)     s="opkg not found; Zsh cannot be installed automatically. Set up Entware/opkg first and retry." ;;
                esac ;;
            e.opkg_not_found)
                case "$lang" in
                    zh-CN) s="未找到 opkg。本安装器面向 Entware 环境。
请先安装 Entware（QNAP：在 App Center 启用 / 通过 Entware QPKG；通用：https://github.com/Entware/Entware）。" ;; zh-TW) s="未找到 opkg。本安裝器面向 Entware 環境。
請先安裝 Entware（QNAP：在 App Center 啟用 / 透過 Entware QPKG；通用：https://github.com/Entware/Entware）。" ;;
                    ja)    s="opkg が見つかりません。このインストーラーは Entware 環境向けです。
先に Entware をインストールしてください（QNAP: App Center で有効化 / Entware QPKG 経由、その他: https://github.com/Entware/Entware）。" ;; ko)    s="opkg를 찾을 수 없습니다. 이 설치 관리자는 Entware 환경용입니다.
먼저 Entware를 설치하세요(QNAP: App Center에서 활성화 / Entware QPKG, 일반: https://github.com/Entware/Entware)." ;;
                    *)     s="opkg not found. This installer targets Entware environments.
Install Entware first (QNAP: enable it in App Center / via the Entware QPKG; generic: https://github.com/Entware/Entware)." ;;
                esac ;;
            i.atuin_official_binary)
                case "$lang" in
                    zh-CN) s="尝试 Atuin 官方安装器（镜像加速拉取 + 二进制）..." ;; zh-TW) s="嘗試 Atuin 官方安裝器（鏡像加速拉取 + 二進位）..." ;;
                    ja)    s="公式 Atuin インストーラーを試します（ミラー加速の取得 + バイナリ）..." ;; ko)    s="공식 Atuin 설치 관리자 시도 중(미러 가속 다운로드 + 바이너리) ..." ;;
                    *)     s="Trying the official Atuin installer (mirror-accelerated fetch + binary) ..." ;;
                esac ;;
            i.entware_detected)
                case "$lang" in
                    zh-CN) s="检测到 Entware —— opkg 路径：%s" ;; zh-TW) s="偵測到 Entware —— opkg 路徑：%s" ;;
                    ja)    s="Entware を検出 — opkg: %s" ;; ko)    s="Entware 감지됨 — opkg: %s" ;;
                    *)     s="Detected Entware — opkg at: %s" ;;
                esac ;;
            i.fzf_not_in_feed)
                case "$lang" in
                    zh-CN) s="fzf 不在 entware feed，尝试官方 git clone 安装（走镜像加速）..." ;; zh-TW) s="fzf 不在 entware feed，嘗試官方 git clone 安裝（走鏡像加速）..." ;;
                    ja)    s="fzf は Entware のフィードにありません — 公式の git clone インストールに切り替えます（ミラー加速）..." ;; ko)    s="fzf가 Entware 피드에 없습니다 — 공식 git clone 설치로 대체합니다(미러 가속) ..." ;;
                    *)     s="fzf is not in the Entware feed — falling back to the official git clone install (mirror-accelerated) ..." ;;
                esac ;;
            i.home_dir)
                case "$lang" in
                    zh-CN) s="主目录：%s" ;; zh-TW) s="主目錄：%s" ;;
                    ja)    s="ホームディレクトリ: %s" ;; ko)    s="홈 디렉터리: %s" ;;
                    *)     s="Home directory: %s" ;;
                esac ;;
            i.omz_installing)
                case "$lang" in
                    zh-CN) s="未检测到 Oh My Zsh，准备安装（官方一键脚本，走镜像加速）..." ;; zh-TW) s="未偵測到 Oh My Zsh，準備安裝（官方一鍵腳本，走鏡像加速）..." ;;
                    ja)    s="Oh My Zsh が見つかりません — インストールします（公式スクリプト、ミラー加速）..." ;; ko)    s="Oh My Zsh 미설치 — 설치합니다(공식 스크립트, 미러 가속) ..." ;;
                    *)     s="Oh My Zsh not found — installing it (official installer, mirror-accelerated) ..." ;;
                esac ;;
            i.plugin_updating)
                case "$lang" in
                    zh-CN) s="zsh-smart-complete 已存在 —— 更新到最新 ..." ;; zh-TW) s="zsh-smart-complete 已存在 —— 更新到最新 ..." ;;
                    ja)    s="zsh-smart-complete は既に存在します — 最新版に更新しています ..." ;; ko)    s="zsh-smart-complete 이미 존재함 — 최신으로 업데이트 중 ..." ;;
                    *)     s="zsh-smart-complete is already present — updating to the latest ..." ;;
                esac ;;
            i.zsh_done_relogin)
                case "$lang" in
                    zh-CN) s="Zsh 安装完成。请重新登录，或执行： exec %s" ;; zh-TW) s="Zsh 安裝完成。請重新登入，或執行： exec %s" ;;
                    ja)    s="Zsh のインストールが完了しました。再ログインまたは実行： exec %s" ;; ko)    s="Zsh 설치 완료. 다시 로그인하거나 실행: exec %s" ;;
                    *)     s="Zsh is ready. Log in again, or run: exec %s" ;;
                esac ;;
            s.atuin_present)
                case "$lang" in
                    zh-CN) s="Atuin 已安装：%s" ;; zh-TW) s="Atuin 已安裝：%s" ;;
                    ja)    s="Atuin はインストール済み: %s" ;; ko)    s="Atuin 설치됨: %s" ;;
                    *)     s="Atuin is installed: %s" ;;
                esac ;;
            s.fzf_installed_git)
                case "$lang" in
                    zh-CN) s="fzf 已通过 git clone 安装（镜像加速）" ;; zh-TW) s="fzf 已透過 git clone 安裝（鏡像加速）" ;;
                    ja)    s="fzf を git clone でインストールしました（ミラー加速）" ;; ko)    s="fzf를 git clone으로 설치(미러 가속)" ;;
                    *)     s="fzf installed via git clone (mirror-accelerated)" ;;
                esac ;;
            s.fzf_installed_opkg)
                case "$lang" in
                    zh-CN) s="fzf 已安装（opkg）" ;; zh-TW) s="fzf 已安裝（opkg）" ;;
                    ja)    s="fzf をインストールしました（opkg）" ;; ko)    s="fzf 설치 완료(opkg)" ;;
                    *)     s="fzf installed (opkg)" ;;
                esac ;;
            s.omz_installed)
                case "$lang" in
                    zh-CN) s="Oh My Zsh 安装完成。" ;; zh-TW) s="Oh My Zsh 安裝完成。" ;;
                    ja)    s="Oh My Zsh のインストールが完了しました。" ;; ko)    s="Oh My Zsh 설치 완료." ;;
                    *)     s="Oh My Zsh installation complete." ;;
                esac ;;
            w.fzf_install_failed_entware)
                case "$lang" in
                    zh-CN) s="fzf 安装失败（插件核心不依赖 fzf，可稍后手动安装）。" ;; zh-TW) s="fzf 安裝失敗（外掛核心不依賴 fzf，可稍後手動安裝）。" ;;
                    ja)    s="fzf のインストールに失敗しました（プラグインコアは fzf を必要としません。後で手動でインストールできます）。" ;; ko)    s="fzf 설치 실패(코어는 fzf가 필요 없으므로 나중에 수동 설치)." ;;
                    *)     s="fzf install failed (the plugin core does not need fzf; install it later)." ;;
                esac ;;
            w.git_pull_failed)
                case "$lang" in
                    zh-CN) s="git pull 失败（不影响继续）" ;; zh-TW) s="git pull 失敗（不影響繼續）" ;;
                    ja)    s="git pull に失敗しました（続行に影響なし）" ;; ko)    s="git pull 실패(치명적이지 않음)" ;;
                    *)     s="git pull failed (non-fatal)" ;;
                esac ;;
            w.not_root)
                case "$lang" in
                    zh-CN) s="当前不是 root（uid=%s）。QNAP 的管理员通常就是 root，继续但不使用 sudo。" ;; zh-TW) s="目前不是 root（uid=%s）。QNAP 的管理員通常就是 root，繼續但不使用 sudo。" ;;
                    ja)    s="root として実行されていません（uid=%s）。QNAP では管理者ユーザーが通常 root です。sudo なしで継続します。" ;; ko)    s="root가 아닙니다(uid=%s). QNAP의 관리자는 보통 root입니다. sudo 없이 계속합니다." ;;
                    *)     s="Not running as root (uid=%s). On QNAP the admin user is normally root; continuing without sudo." ;;
                esac ;;
            w.omz_kept)
                case "$lang" in
                    zh-CN) s="Oh My Zsh 已安装，保留。" ;; zh-TW) s="Oh My Zsh 已安裝，保留。" ;;
                    ja)    s="Oh My Zsh はインストール済みです。そのまま保持します。" ;; ko)    s="Oh My Zsh 설치됨 — 유지합니다." ;;
                    *)     s="Oh My Zsh is installed — keeping it." ;;
                esac ;;
            w.omz_skipped)
                case "$lang" in
                    zh-CN) s="已跳过 Oh My Zsh 安装；将按 Zinit + Starship 组合继续。" ;; zh-TW) s="已跳過 Oh My Zsh 安裝；將按 Zinit + Starship 組合繼續。" ;;
                    ja)    s="Oh My Zsh のインストールをスキップしました。Zinit + Starship 構成で続行します。" ;; ko)    s="Oh My Zsh 건너뜀; Zinit + Starship 조합으로 계속합니다." ;;
                    *)     s="Skipped Oh My Zsh; continuing with the Zinit + Starship combo." ;;
                esac ;;
            w.omz_failed)
                case "$lang" in
                    zh-CN) s="Oh My Zsh 安装失败（可能网络受限）；将按 Zinit + Starship 组合继续。" ;; zh-TW) s="Oh My Zsh 安裝失敗（可能網路受限）；將按 Zinit + Starship 組合繼續。" ;;
                    ja)    s="Oh My Zsh のインストールに失敗しました（通信制限の可能性あり）。Zinit + Starship 構成で続行します。" ;; ko)    s="Oh My Zsh 설치 실패(네트워크 제한 가능성); Zinit + Starship 조합으로 계속합니다." ;;
                    *)     s="Oh My Zsh install failed (possibly a network limit); continuing with the Zinit + Starship combo." ;;
                esac ;;
            w.zsh_theme_write_failed)
                case "$lang" in
                    zh-CN) s="写入 %s 失败，请手动设置 ZSH_THEME=\"%s\"" ;; zh-TW) s="寫入 %s 失敗，請手動設定 ZSH_THEME=\"%s\"" ;;
                    ja)    s="%s への書き込みに失敗しました。手動で ZSH_THEME=\"%s\" を設定してください" ;; ko)    s="%s 쓰기 실패. 수동으로 ZSH_THEME=\"%s\" 설정" ;;
                    *)     s="Could not write %s. Set it manually: ZSH_THEME=\"%s\"" ;;
                esac ;;
            s.zsh_theme_set)
                case "$lang" in
                    zh-CN) s="已设置 ZSH_THEME=\"%s\"" ;; zh-TW) s="已設定 ZSH_THEME=\"%s\"" ;;
                    ja)    s="ZSH_THEME=\"%s\" を設定しました" ;; ko)    s="ZSH_THEME=\"%s\" 설정 완료" ;;
                    *)     s="Set ZSH_THEME=\"%s\"" ;;
                esac ;;
            s.zsh_theme_appended)
                case "$lang" in
                    zh-CN) s="已追加 ZSH_THEME=\"%s\" 到 %s" ;; zh-TW) s="已追加 ZSH_THEME=\"%s\" 到 %s" ;;
                    ja)    s="ZSH_THEME=\"%s\" を %s に追加しました" ;; ko)    s="%s 에 ZSH_THEME=\"%s\" 추가 완료" ;;
                    *)     s="Appended ZSH_THEME=\"%s\" to %s" ;;
                esac ;;
            w.plugin_update_failed)
                case "$lang" in
                    zh-CN) s="zsh-smart-complete 更新失败（不影响继续）；保留现有代码。" ;; zh-TW) s="zsh-smart-complete 更新失敗（不影響繼續）；保留現有程式碼。" ;;
                    ja)    s="zsh-smart-complete の更新に失敗しました（続行に影響なし）。既存のコードを保持します。" ;; ko)    s="zsh-smart-complete 업데이트 실패(치명적이지 않음); 기존 코드 유지." ;;
                    *)     s="zsh-smart-complete update failed (non-fatal); the existing code was kept." ;;
                esac ;;
            w.plugin_update_skipped)
                case "$lang" in
                    zh-CN) s="跳过更新 %s（不影响继续）。" ;; zh-TW) s="跳過更新 %s（不影響繼續）。" ;;
                    ja)    s="%s の更新をスキップしました（続行に影響なし）。" ;; ko)    s="%s 업데이트 건너뜀(치명적이지 않음)." ;;
                    *)     s="Update skipped for %s (non-fatal)." ;;
                esac ;;
            w.zinit_dep_clone_failed)
                case "$lang" in
                    zh-CN) s="克隆 %s 失败（不影响继续；Zinit 会在首次启动 shell 时自动获取）。" ;; zh-TW) s="複製 %s 失敗（不影響繼續；Zinit 會在首次啟動 shell 時自動取得）。" ;;
                    ja)    s="%s のクローンに失敗しました（続行に影響なし。Zinit が初回シェル起動時に取得します）。" ;; ko)    s="%s 복제 실패(치명적이지 않음; Zinit이 첫 셸 시작 시 가져옵니다)." ;;
                    *)     s="Clone failed for %s (non-fatal; Zinit fetches it at the first shell start)." ;;
                esac ;;
            w.zsh_missing_entware)
                case "$lang" in
                    zh-CN) s="未检测到 Zsh —— 本插件依赖 Zsh，将通过 opkg 安装。" ;; zh-TW) s="未偵測到 Zsh —— 本外掛依賴 Zsh，將透過 opkg 安裝。" ;;
                    ja)    s="Zsh が見つかりません — 本プラグインは Zsh が必要なため、opkg でインストールします。" ;; ko)    s="Zsh을 찾을 수 없습니다 — 본 플러그인에는 Zsh이 필요하므로 opkg로 설치합니다." ;;
                    *)     s="Zsh not found — this plugin requires Zsh; installing it with opkg." ;;
                esac ;;
            combo.detected_installed)
                case "$lang" in
                    zh-CN) s="已检测到已安装：%s。" ;; zh-TW) s="已偵測到已安裝：%s。" ;;
                    ja)    s="インストール済みを検出しました: %s。" ;; ko)    s="이미 설치됨 감지: %s." ;;
                    *)     s="Detected already installed: %s." ;;
                esac ;;
            combo.env)
                case "$lang" in
                    zh-CN) s="配置组合（来自 SMART_INSTALL_COMBO）：%s" ;; zh-TW) s="配置組合（來自 SMART_INSTALL_COMBO）：%s" ;;
                    ja)    s="構成（SMART_INSTALL_COMBO 由来）: %s" ;; ko)    s="구성 조합(SMART_INSTALL_COMBO 지정): %s" ;;
                    *)     s="Configuration combo (from SMART_INSTALL_COMBO): %s" ;;
                esac ;;
            combo.headless_auto)
                case "$lang" in
                    zh-CN) s="(headless) 推荐配置：Zinit + Starship。" ;; zh-TW) s="(headless) 推薦配置：Zinit + Starship。" ;;
                    ja)    s="(headless) 推奨構成: Zinit + Starship。" ;; ko)    s="(headless) 권장 구성: Zinit + Starship." ;;
                    *)     s="(headless) recommended configuration: Zinit + Starship." ;;
                esac ;;
            combo.prompt)
                case "$lang" in
                    zh-CN) s="选择配置组合（推荐 Zinit + Starship，也可选用 Oh My Zsh / Powerlevel10k 备选）：" ;; zh-TW) s="選擇配置組合（推薦 Zinit + Starship，也可選用 Oh My Zsh / Powerlevel10k 備選）：" ;;
                    ja)    s="構成を選択してください（推奨: Zinit + Starship、代替として Oh My Zsh / Powerlevel10k も可）:" ;; ko)    s="구성 조합 선택 (권장: Zinit + Starship, 대안: Oh My Zsh / Powerlevel10k):" ;;
                    *)     s="Select a configuration combo (recommended: Zinit + Starship; Oh My Zsh / Powerlevel10k as alternatives):" ;;
                esac ;;
            combo.unknown_env)
                case "$lang" in
                    zh-CN) s="未知的 SMART_INSTALL_COMBO='%s'，忽略并回退到交互选择。" ;; zh-TW) s="未知的 SMART_INSTALL_COMBO='%s'，忽略並回退到互動選擇。" ;;
                    ja)    s="不明な SMART_INSTALL_COMBO='%s'。無視して対話選択に戻します。" ;; ko)    s="알 수 없는 SMART_INSTALL_COMBO='%s'. 무시하고 대화형 선택으로 진행." ;;
                    *)     s="Unknown SMART_INSTALL_COMBO='%s'; ignoring it and falling back to the interactive choice." ;;
                esac ;;
            dl.clone_fallback)
                case "$lang" in
                    zh-CN) s="镜像 clone 失败，回退直连：%s" ;; zh-TW) s="鏡像 clone 失敗，回退直連：%s" ;;
                    ja)    s="ミラー経由のクローンに失敗しました。直接接続に戻します: %s" ;; ko)    s="미러 clone 실패, 직접 연결로 대체: %s" ;;
                    *)     s="Mirror clone failed; falling back to a direct connection: %s" ;;
                esac ;;
            dl.direct_ok2)
                case "$lang" in
                    zh-CN) s="直连重试成功" ;; zh-TW) s="直連重試成功" ;;
                    ja)    s="直接接続の再試行に成功しました" ;; ko)    s="직접 재시도 성공" ;;
                    *)     s="Direct retry succeeded" ;;
                esac ;;
            dl.mirror_failed2)
                case "$lang" in
                    zh-CN) s="镜像加速下载失败（exit %s），回退直连重试 ..." ;; zh-TW) s="鏡像加速下載失敗（exit %s），回退直連重試 ..." ;;
                    ja)    s="ミラー経由のダウンロードに失敗しました（exit %s）。直接接続で再試行します ..." ;; ko)    s="미러 다운로드 실패(exit %s). 직접 재시도 ..." ;;
                    *)     s="Mirror download failed (exit %s); falling back to a direct retry ..." ;;
                esac ;;
            dl.proxy_failed)
                case "$lang" in
                    zh-CN) s="全量代理下载失败（exit %s），撤掉代理直连重试 ..." ;; zh-TW) s="全量代理下載失敗（exit %s），撤掉代理直連重試 ..." ;;
                    ja)    s="プロキシ経由のダウンロードに失敗しました（exit %s）。プロキシなしで再試行します ..." ;; ko)    s="전체 프록시 다운로드 실패(exit %s). 프록시 없이 재시도 ..." ;;
                    *)     s="Full-proxy download failed (exit %s); retrying without the proxy ..." ;;
                esac ;;
            e.opkg_install_zsh_failed)
                case "$lang" in
                    zh-CN) s="opkg install zsh 失败，请检查 Entware feed / 网络连接。" ;; zh-TW) s="opkg install zsh 失敗，請檢查 Entware feed / 網路連線。" ;;
                    ja)    s="opkg install zsh に失敗しました。Entware のフィード / ネットワーク接続を確認してください。" ;; ko)    s="opkg install zsh 실패. Entware 피드 / 네트워크 연결을 확인하세요." ;;
                    *)     s="opkg install zsh failed; check the Entware feed / network connection." ;;
                esac ;;
            i.combo_kept_omz_p10k)
                case "$lang" in
                    zh-CN) s="已选择：Oh My Zsh + Powerlevel10k（经典方案）。" ;; zh-TW) s="已選擇：Oh My Zsh + Powerlevel10k（經典方案）。" ;;
                    ja)    s="選択: Oh My Zsh + Powerlevel10k（定番構成）。" ;; ko)    s="선택: Oh My Zsh + Powerlevel10k(클래식)." ;;
                    *)     s="Selected: Oh My Zsh + Powerlevel10k (classic)." ;;
                esac ;;
            i.combo_recommended)
                case "$lang" in
                    zh-CN) s="已选择（推荐）：Zinit + Starship。" ;; zh-TW) s="已選擇（推薦）：Zinit + Starship。" ;;
                    ja)    s="選択（推奨）: Zinit + Starship。" ;; ko)    s="선택(권장): Zinit + Starship." ;;
                    *)     s="Selected (recommended): Zinit + Starship." ;;
                esac ;;
            i.combo_zinit_p10k)
                case "$lang" in
                    zh-CN) s="已选择：Zinit + Powerlevel10k。" ;; zh-TW) s="已選擇：Zinit + Powerlevel10k。" ;;
                    ja)    s="選択: Zinit + Powerlevel10k。" ;; ko)    s="선택: Zinit + Powerlevel10k." ;;
                    *)     s="Selected: Zinit + Powerlevel10k." ;;
                esac ;;
            i.installing_zsh_opkg)
                case "$lang" in
                    zh-CN) s="正在通过 opkg 安装 zsh ..." ;; zh-TW) s="正在透過 opkg 安裝 zsh ..." ;;
                    ja)    s="opkg で zsh をインストールしています ..." ;; ko)    s="opkg로 zsh 설치 중 ..." ;;
                    *)     s="Installing zsh via opkg ..." ;;
                esac ;;
            i.no_zshrc_creating)
                case "$lang" in
                    zh-CN) s="未发现 ~/.zshrc —— 正在创建推荐配置（含 zsh-smart-complete 块）..." ;; zh-TW) s="未發現 ~/.zshrc —— 正在建立推薦配置（含 zsh-smart-complete 區塊）..." ;;
                    ja)    s="~/.zshrc が見つかりません — 推奨構成（zsh-smart-complete ブロック付き）を作成しています ..." ;; ko)    s="~/.zshrc 없음 — 권장 설정 생성 중(zsh-smart-complete 블록 포함) ..." ;;
                    *)     s="No ~/.zshrc found — creating a recommended one (with the zsh-smart-complete block) ..." ;;
                esac ;;
            i.opkg_no_starship)
                case "$lang" in
                    zh-CN) s="opkg 无 starship，尝试官方一键安装（走镜像加速）..." ;; zh-TW) s="opkg 無 starship，嘗試官方一鍵安裝（走鏡像加速）..." ;;
                    ja)    s="opkg に starship がありません。公式ワンクリックインストーラーを試します（ミラー加速）..." ;; ko)    s="opkg에 starship 없음. 공식 원클릭 설치 시도(미러 가속) ..." ;;
                    *)     s="No starship in opkg; trying the official one-click installer (mirror-accelerated) ..." ;;
                esac ;;
            i.p10k_installing)
                case "$lang" in
                    zh-CN) s="未检测到 Powerlevel10k，作为 Oh My Zsh 主题安装..." ;; zh-TW) s="未偵測到 Powerlevel10k，作為 Oh My Zsh 主題安裝..." ;;
                    ja)    s="Powerlevel10k が見つかりません — Oh My Zsh のテーマとしてインストールします..." ;; ko)    s="Powerlevel10k 미설치 — Oh My Zsh 테마로 설치합니다..." ;;
                    *)     s="Powerlevel10k not found — installing it as an Oh My Zsh theme ..." ;;
                esac ;;
            i.p10k_kept)
                case "$lang" in
                    zh-CN) s="Powerlevel10k 已安装，保留。" ;; zh-TW) s="Powerlevel10k 已安裝，保留。" ;;
                    ja)    s="Powerlevel10k はインストール済みです。そのまま保持します。" ;; ko)    s="Powerlevel10k 설치됨 — 유지합니다." ;;
                    *)     s="Powerlevel10k is installed — keeping it." ;;
                esac ;;
            i.p10k_zinit_auto)
                case "$lang" in
                    zh-CN) s="Zinit 将在首次启动 shell 时自动克隆并加载 Powerlevel10k。" ;; zh-TW) s="Zinit 將在首次啟動 shell 時自動複製並載入 Powerlevel10k。" ;;
                    ja)    s="Zinit が初回シェル起動時に Powerlevel10k を自動でクローンして読み込みます。" ;; ko)    s="Zinit이 첫 셸 시작 시 Powerlevel10k를 자동 복제·로드합니다." ;;
                    *)     s="Zinit clones and loads Powerlevel10k automatically at the first shell start." ;;
                esac ;;
            i.p10k_zinit_kept)
                case "$lang" in
                    zh-CN) s="Powerlevel10k 已安装，保留（将由 Zinit 加载）。" ;; zh-TW) s="Powerlevel10k 已安裝，保留（將由 Zinit 載入）。" ;;
                    ja)    s="Powerlevel10k はインストール済みです（Zinit が読み込みます）。" ;; ko)    s="Powerlevel10k 설치됨 — 유지합니다(Zinit이 로드)." ;;
                    *)     s="Powerlevel10k is installed — keeping it (loaded by Zinit)." ;;
                esac ;;
            i.profile_already_zsh)
                case "$lang" in
                    zh-CN) s="%s 已启动 zsh（跳过）" ;; zh-TW) s="%s 已啟動 zsh（跳過）" ;;
                    ja)    s="%s は既に zsh を起動しています（スキップ）" ;; ko)    s="%s 이미 zsh 실행 중(건너뜀)" ;;
                    *)     s="%s already launches zsh (skipping)" ;;
                esac ;;
            i.switching_login_shell)
                case "$lang" in
                    zh-CN) s="正在把登录 shell 切换为 zsh ..." ;; zh-TW) s="正在把登入 shell 切換為 zsh ..." ;;
                    ja)    s="ログインシェルを zsh に切り替えています ..." ;; ko)    s="로그인 셸을 zsh로 전환 중 ..." ;;
                    *)     s="Switching your login shell to zsh ..." ;;
                esac ;;
            i.trying_opkg_starship)
                case "$lang" in
                    zh-CN) s="尝试用 opkg 安装 starship ..." ;; zh-TW) s="嘗試用 opkg 安裝 starship ..." ;;
                    ja)    s="opkg で starship のインストールを試します ..." ;; ko)    s="opkg로 starship 설치 시도 중 ..." ;;
                    *)     s="Trying opkg install starship ..." ;;
                esac ;;
            mirror.all_down)
                case "$lang" in
                    zh-CN) s="所有镜像均不可用，回退到直连。" ;; zh-TW) s="所有鏡像均不可用，回退到直連。" ;;
                    ja)    s="すべてのミラーが利用不可のため、直接接続に戻します。" ;; ko)    s="모든 미러를 사용할 수 없어 직접 연결로 대체합니다." ;;
                    *)     s="All mirrors are unavailable; falling back to a direct connection." ;;
                esac ;;
            mirror.auto_fastest)
                case "$lang" in
                    zh-CN) s="已自动选择最快镜像：%s (%ss) [%s]" ;; zh-TW) s="已自動選擇最快鏡像：%s (%ss) [%s]" ;;
                    ja)    s="最速のミラーを自動選択しました: %s (%ss) [%s]" ;; ko)    s="가장 빠른 미러 자동 선택: %s (%ss) [%s]" ;;
                    *)     s="Auto-selected the fastest mirror: %s (%ss) [%s]" ;;
                esac ;;
            mirror.custom_chosen2)
                case "$lang" in
                    zh-CN) s="使用自定义镜像：%s [%s]" ;; zh-TW) s="使用自訂鏡像：%s [%s]" ;;
                    ja)    s="カスタムミラーを使用します: %s [%s]" ;; ko)    s="사용자 지정 미러 사용: %s [%s]" ;;
                    *)     s="Using a custom mirror: %s [%s]" ;;
                esac ;;
            mirror.direct)
                case "$lang" in
                    zh-CN) s="直连" ;; zh-TW) s="直連" ;;
                    ja)    s="直接接続" ;; ko)    s="직접 연결" ;;
                    *)     s="direct" ;;
                esac ;;
            mirror.gh_env)
                case "$lang" in
                    zh-CN) s="GitHub 加速镜像（来自 SMART_INSTALL_GH_MIRROR）：%s [%s]" ;; zh-TW) s="GitHub 加速鏡像（來自 SMART_INSTALL_GH_MIRROR）：%s [%s]" ;;
                    ja)    s="GitHub ミラー（SMART_INSTALL_GH_MIRROR 由来）: %s [%s]" ;; ko)    s="GitHub 미러(SMART_INSTALL_GH_MIRROR 지정): %s [%s]" ;;
                    *)     s="GitHub mirror (from SMART_INSTALL_GH_MIRROR): %s [%s]" ;;
                esac ;;
            mirror.skip_deps)
                case "$lang" in
                    zh-CN) s="SKIP_DEPS=1：跳过镜像测速，使用直连。" ;; zh-TW) s="SKIP_DEPS=1：跳過鏡像測速，使用直連。" ;;
                    ja)    s="SKIP_DEPS=1: ミラー速度測定をスキップし、直接接続します。" ;; ko)    s="SKIP_DEPS=1: 미러 속도 측정을 건너뛰고 직접 연결합니다." ;;
                    *)     s="SKIP_DEPS=1: skipping the mirror speed test, using a direct connection." ;;
                esac ;;
            mirror.unavailable_line)
                case "$lang" in
                    zh-CN) s="%s -> 不可用 (HTTP %s)" ;; zh-TW) s="%s -> 不可用 (HTTP %s)" ;;
                    ja)    s="%s -> 利用不可 (HTTP %s)" ;; ko)    s="%s -> 사용 불가 (HTTP %s)" ;;
                    *)     s="%s -> unavailable (HTTP %s)" ;;
                esac ;;
            s.backed_up_removed_omz)
                case "$lang" in
                    zh-CN) s="已备份并移除 ~/.oh-my-zsh" ;; zh-TW) s="已備份並移除 ~/.oh-my-zsh" ;;
                    ja)    s="~/.oh-my-zsh をバックアップして削除しました" ;; ko)    s="~/.oh-my-zsh 백업 후 삭제 완료" ;;
                    *)     s="Backed up + removed ~/.oh-my-zsh" ;;
                esac ;;
            s.backed_up_removed_p10k)
                case "$lang" in
                    zh-CN) s="已备份并移除 ~/.p10k.zsh" ;; zh-TW) s="已備份並移除 ~/.p10k.zsh" ;;
                    ja)    s="~/.p10k.zsh をバックアップして削除しました" ;; ko)    s="~/.p10k.zsh 백업 후 삭제 완료" ;;
                    *)     s="Backed up + removed ~/.p10k.zsh" ;;
                esac ;;
            s.backed_up_removed_path)
                case "$lang" in
                    zh-CN) s="已备份并移除：%s" ;; zh-TW) s="已備份並移除：%s" ;;
                    ja)    s="バックアップして削除しました: %s" ;; ko)    s="백업 후 삭제: %s" ;;
                    *)     s="Backed up + removed: %s" ;;
                esac ;;
            s.commented_lines)
                case "$lang" in
                    zh-CN) s="已注释掉 ~/.zshrc 中包含 '%s' 的生效行（已备份）" ;; zh-TW) s="已註解掉 ~/.zshrc 中包含 '%s' 的生效行（已備份）" ;;
                    ja)    s="~/.zshrc 内の '%s' を含む有効行をコメントアウトしました（バックアップあり）" ;; ko)    s="~/.zshrc 에서 '%s' 항목을 주석 처리했습니다(백업 보관)" ;;
                    *)     s="Commented out active lines containing '%s' in ~/.zshrc (backup kept)" ;;
                esac ;;
            s.no_conflict)
                case "$lang" in
                    zh-CN) s="未检测到 %s 冲突" ;; zh-TW) s="未偵測到 %s 衝突" ;;
                    ja)    s="%s の競合は検出されませんでした" ;; ko)    s="%s 충돌 없음" ;;
                    *)     s="No %s conflict detected" ;;
                esac ;;
            s.p10k_cloned)
                case "$lang" in
                    zh-CN) s="Powerlevel10k 已克隆到 %s" ;; zh-TW) s="Powerlevel10k 已複製到 %s" ;;
                    ja)    s="Powerlevel10k を %s にクローンしました" ;; ko)    s="Powerlevel10k를 %s 에 복제 완료" ;;
                    *)     s="Powerlevel10k cloned to %s" ;;
                esac ;;
            s.profile_launch_added)
                case "$lang" in
                    zh-CN) s="已向 %s 追加 'exec %s'" ;; zh-TW) s="已向 %s 追加 'exec %s'" ;;
                    ja)    s="%s に 'exec %s' を追加しました" ;; ko)    s="%s 에 'exec %s' 추가 완료" ;;
                    *)     s="Added 'exec %s' to %s" ;;
                esac ;;
            s.removed_p10k_dir)
                case "$lang" in
                    zh-CN) s="已移除 ~/.powerlevel10k" ;; zh-TW) s="已移除 ~/.powerlevel10k" ;;
                    ja)    s="~/.powerlevel10k を削除しました" ;; ko)    s="~/.powerlevel10k 삭제 완료" ;;
                    *)     s="Removed ~/.powerlevel10k" ;;
                esac ;;
            s.starship_official_installed)
                case "$lang" in
                    zh-CN) s="Starship 已安装（官方安装器，镜像加速）" ;; zh-TW) s="Starship 已安裝（官方安裝器，鏡像加速）" ;;
                    ja)    s="Starship をインストールしました（公式インストーラー、ミラー加速）" ;; ko)    s="Starship 설치 완료(공식 설치 관리자, 미러 가속)" ;;
                    *)     s="Starship installed (official installer, mirror-accelerated)" ;;
                esac ;;
            s.starship_present2)
                case "$lang" in
                    zh-CN) s="Starship 已存在：%s" ;; zh-TW) s="Starship 已存在：%s" ;;
                    ja)    s="Starship あり: %s" ;; ko)    s="Starship 존재: %s" ;;
                    *)     s="Starship present: %s" ;;
                esac ;;
            s.zinit_installed_path)
                case "$lang" in
                    zh-CN) s="Zinit 已安装在 %s" ;; zh-TW) s="Zinit 已安裝於 %s" ;;
                    ja)    s="Zinit は %s にインストール済みです" ;; ko)    s="Zinit 설치 위치: %s" ;;
                    *)     s="Zinit is installed at %s" ;;
                esac ;;
            s.zsh_installed_at)
                case "$lang" in
                    zh-CN) s="Zsh 已安装到 %s" ;; zh-TW) s="Zsh 已安裝於 %s" ;;
                    ja)    s="Zsh を %s にインストールしました" ;; ko)    s="Zsh 설치 위치: %s" ;;
                    *)     s="Zsh installed at %s" ;;
                esac ;;
            s.zshrc_created_with_block)
                case "$lang" in
                    zh-CN) s="已创建 %s（含 zsh-smart-complete 集成）" ;; zh-TW) s="已建立 %s（含 zsh-smart-complete 整合）" ;;
                    ja)    s="%s を作成しました（zsh-smart-complete 連携付き）" ;; ko)    s="%s 생성 완료(zsh-smart-complete 연동 포함)" ;;
                    *)     s="%s created (with zsh-smart-complete integration)" ;;
                esac ;;
            s.zshrc_file_updated)
                case "$lang" in
                    zh-CN) s="%s 已更新（备份在 .bak.*）" ;; zh-TW) s="%s 已更新（備份在 .bak.*）" ;;
                    ja)    s="%s を更新しました（バックアップ: .bak.*）" ;; ko)    s="%s 업데이트 완료(백업: .bak.*)" ;;
                    *)     s="%s updated (backup kept at .bak.*)" ;;
                esac ;;
            s.zshrc_updated_backup)
                case "$lang" in
                    zh-CN) s="%s 已引用 zsh-smart-complete —— 已刷新选项块（备份在 .bak.*）" ;; zh-TW) s="%s 已引用 zsh-smart-complete —— 已重新整理選項區塊（備份在 .bak.*）" ;;
                    ja)    s="%s は既に zsh-smart-complete を参照しています — オプションブロックを更新しました（バックアップ: .bak.*）" ;; ko)    s="%s 이미 zsh-smart-complete 참조 — 옵션 블록 갱신(백업: .bak.*)" ;;
                    *)     s="%s already references zsh-smart-complete — options block refreshed (backup kept at .bak.*)" ;;
                esac ;;
            w.p10k_clone_failed)
                case "$lang" in
                    zh-CN) s="Powerlevel10k 克隆失败（可稍后手动安装）。" ;; zh-TW) s="Powerlevel10k 複製失敗（可稍後手動安裝）。" ;;
                    ja)    s="Powerlevel10k のクローンに失敗しました（後で手動インストールできます）。" ;; ko)    s="Powerlevel10k 복제 실패(나중에 수동 설치)." ;;
                    *)     s="Powerlevel10k clone failed (install it later)." ;;
                esac ;;
            w.qnap_gui_hint)
                case "$lang" in
                    zh-CN) s="或在 QNAP 界面设置登录 shell：控制面板 -> 终端机 -> 默认 shell -> zsh" ;; zh-TW) s="或在 QNAP 介面設定登入 shell：控制台 -> 終端機 -> 預設 shell -> zsh" ;;
                    ja)    s="または QNAP の GUI でログインシェルを設定してください: コントロールパネル -> ターミナル -> デフォルトシェル -> zsh" ;; ko)    s="또는 QNAP GUI에서 로그인 셸 설정: 제어판 -> 터미널 -> 기본 셸 -> zsh" ;;
                    *)     s="Or set the login shell via the QNAP GUI: Control Panel -> Terminal -> Default shell -> zsh" ;;
                esac ;;
            w.skipped_removal_1)
                case "$lang" in
                    zh-CN) s="已跳过移除 %s；与 zsh-smart-complete 同时启用可能导致重复建议 / Tab 冲突。" ;; zh-TW) s="已跳過移除 %s；與 zsh-smart-complete 同時啟用可能導致重複建議 / Tab 衝突。" ;;
                    ja)    s="%s の削除をスキップしました。zsh-smart-complete と併用すると、提案の重複や Tab の競合が起きる可能性があります。" ;; ko)    s="%s 제거를 건너뛰었습니다. zsh-smart-complete와 함께 사용하면 중복 제안 / Tab 충돌이 발생할 수 있습니다." ;;
                    *)     s="Skipped %s removal; running it alongside zsh-smart-complete may cause duplicate suggestions / Tab conflicts." ;;
                esac ;;
            w.starship_install_failed_soft)
                case "$lang" in
                    zh-CN) s="starship 安装失败（可稍后手动安装；插件核心不依赖 starship）。" ;; zh-TW) s="starship 安裝失敗（可稍後手動安裝；外掛核心不依賴 starship）。" ;;
                    ja)    s="starship のインストールに失敗しました（後で手動インストール可。コアは不要です）。" ;; ko)    s="starship 설치 실패(나중에 수동 설치; 코어는 starship이 필요 없음)." ;;
                    *)     s="starship install failed (install it later; the plugin core does not need starship)." ;;
                esac ;;
            mirror.timing_line)
                case "$lang" in
                    zh-CN) s="%s -> %ss" ;; zh-TW) s="%s -> %ss" ;;
                    ja)    s="%s -> %ss" ;; ko)    s="%s -> %ss" ;;
                    *)     s="%s -> %ss" ;;
                esac ;;
    esac
    printf '%s' "$s"
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

# ------------------------------------------------------------------
# Script identity / helpers
# ------------------------------------------------------------------
# $BASH_SOURCE[0] is UNSET when the script arrives on stdin — i.e. for the
# documented `curl -fsSL … | bash` — so guard it. Without the guard, `set -u`
# prints "BASH_SOURCE[0]: unbound variable" and SCRIPT_DIR silently becomes the
# caller's CWD, which a run from a directory that happens to hold templates/
# would then mistake for a local clone.
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
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

# 候选镜像：id | label | prefix | type
#   direct = 直连（prefix 为空）
#   prefix = URL 前缀代理，可加速 raw 文件与 releases 二进制下载（ghproxy 系列）
#   domain = 域名替换型，仅替换 github.com 主机；raw.githubusercontent.com 不支持，保持直连
#   clone  = 仅加速 git clone 的仓库地址；绝不改写 releases / archive / raw 等文件下载
#            否则会把二进制下载地址拼成 404 —— 这正是 starship/atuin 安装报
#            "curl exit code 22" 的根因（gitclone.com 不是前缀代理）
MIRROR_IDS=(); MIRROR_LABELS=(); MIRROR_PREFIXES=(); MIRROR_TYPES=()
# MIRROR_ACTIVE：本轮真正参与「测速 + 菜单」的候选索引。默认是全部候选；
# 非中国大陆时 _build_mirror_pool 会把预置镜像从这里剔除。
# 测速、排序、菜单编号必须共用这一份「可见列表」，否则编号会错位留出空选项。
MIRROR_ACTIVE=()
_add_mirror() {
    local idx=${#MIRROR_IDS[@]}
    MIRROR_IDS+=("$1"); MIRROR_LABELS+=("$2"); MIRROR_PREFIXES+=("$3"); MIRROR_TYPES+=("${4:-prefix}")
    MIRROR_ACTIVE+=("$idx")
}
# 预置加速镜像都是面向中国大陆网络的通道，标签统一标注“适用于中国大陆”，
# 避免非中国区用户误选一个对自己反而更慢的通道。direct 不标注——它对任何地区都适用。
_add_mirror "direct"             "直连（不使用加速）"                              ""                            "direct"
_add_mirror "ghproxy.net"        "ghproxy.net (URL 前缀代理，适用于中国大陆)"       "https://ghproxy.net/"        "prefix"
_add_mirror "ghproxy.com"        "ghproxy.com (URL 前缀代理，适用于中国大陆)"       "https://ghproxy.com/"        "prefix"
_add_mirror "mirror.ghproxy.com" "mirror.ghproxy.com（适用于中国大陆）"             "https://mirror.ghproxy.com/" "prefix"
_add_mirror "gitclone.com"       "gitclone.com (仅 Git Clone 加速，适用于中国大陆)" "https://gitclone.com/"       "clone"

GH_MIRROR_TYPE="direct"   # 与 GH_MIRROR 配套：当前所选镜像的类型

# 由镜像值推断类型：完整 URL 前缀 -> prefix；裸域名 -> domain；空 -> direct
_guess_mirror_type() {
    local v="$1"
    [[ -z "$v" ]] && { echo direct; return 0; }
    case "$v" in
        http://*|https://*) echo prefix ;;
        *)                  echo domain ;;
    esac
}

# 用于测速的小文件（本项目 raw）
MIRROR_TEST_URL="https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/VERSION"
# clone 类镜像只加速仓库地址，用它自己的 URL 形态测速（避免拿直连速度冒充）
MIRROR_TEST_URL_CLONE="https://github.com/imonior/zsh-smart-complete"
MIRROR_TIMES=()   # 与各数组平行，按索引

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

# 测速：必须 HTTP 200 且响应体非空才算可用。
# 只判断“有没有返回耗时”是不够的——返回快速错误页的镜像（如前缀拼错的 gitclone，
# 实测 404）会被误判为最快并被推荐，进而让后续所有下载 404。
mirror_speed_test() {
    local i prefix type u out code t
    local body; body="$(mktemp)"
    # 只测 MIRROR_ACTIVE（可见候选）：非中国大陆时预置镜像已被剔除，不再白跑测速
    for i in "${MIRROR_ACTIVE[@]}"; do
        prefix="${MIRROR_PREFIXES[$i]}"
        type="${MIRROR_TYPES[$i]}"
        if [[ "$type" == "clone" ]]; then
            u="$(_rewrite_with "$type" "$prefix" "$MIRROR_TEST_URL_CLONE")"
        else
            u="$(_rewrite_with "$type" "$prefix" "$MIRROR_TEST_URL")"
        fi
        out="$(curl -sL -o "$body" -w '%{http_code} %{time_total}' --connect-timeout 5 --max-time 12 "$u" 2>/dev/null || true)"
        code="${out%% *}"; t="${out##* }"
        if [[ "$code" == "200" && -s "$body" && "$t" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            MIRROR_TIMES[$i]="$t"
            info "$(msg mirror.timing_line "${MIRROR_LABELS[$i]}" "${t}")"
        else
            MIRROR_TIMES[$i]="999"
            warn "$(msg mirror.unavailable_line "${MIRROR_LABELS[$i]}" "${code:-000}")"
        fi
    done
    rm -f "$body"
}

# 返回按测速升序排列的索引列表（空格分隔）。只排可见候选 MIRROR_ACTIVE。
mirror_ordered_indices() {
    local i
    for i in "${MIRROR_ACTIVE[@]}"; do
        echo "${MIRROR_TIMES[$i]} $i"
    done | sort -n -k1 | awk '{print $2}'
}

# ------------------------------------------------------------------
# 全量代理（系统代理）：proxy 类型
# ------------------------------------------------------------------
# 与“镜像加速”是两种完全不同的机制，别混为一谈：
#   镜像     = 改写 URL 的前缀/域名，只有 GitHub 系地址受益，其余下载照旧直连
#   全量代理 = 导出 HTTP_PROXY/HTTPS_PROXY，curl/git/wget 透明使用，
#              所有外网请求都走它 —— 也就是能设成“系统代理”的那种代理
# 所以 proxy 类型下 mirror_rewrite 必须保持 URL 原样（见 _rewrite_with）。

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

# ------------------------------------------------------------------
# 外网 IP 归属地检测
# ------------------------------------------------------------------
# 归属地只有三种结果：中国大陆 / 非中国大陆 / 没检测出来，各自“可见候选”不同：
#   CN      全部候选（direct + 预置镜像），全部测速，保留两项手动输入
#   没检测出来  同上 —— 地区不明时保守处理，把选择权留给用户，不做隐藏
#   OTHER   剔除预置镜像，只留 direct；direct 仍然测速，两项手动输入仍然保留
# 预置镜像全是面向中国大陆网络的通道，在非中国区既不会更快、还可能更慢，
# 留着只会误导；但“直连是否真的通”是要测出来的，不能靠地区猜，
# 所以 OTHER 分支不短路到直连，而是照常对 direct 测速。
# 归属地查询优先用国内服务（中国区可稳定访问），失败再退回国际服务。
_PUB_IP=""; _PUB_IP_COUNTRY=""; _PUB_IP_DESC=""

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

select_mirror() {
    # 环境变量覆盖：前缀 URL，或 direct/none 关闭
    if [[ -n "${SMART_INSTALL_GH_MIRROR:-}" ]]; then
        case "${SMART_INSTALL_GH_MIRROR}" in
            direct|none|'') GH_MIRROR=""; GH_MIRROR_TYPE="direct" ;;
            *)
                GH_MIRROR="${SMART_INSTALL_GH_MIRROR}"
                GH_MIRROR_TYPE="$(_guess_mirror_type "$GH_MIRROR")"
                ;;
        esac
        info "$(msg mirror.gh_env "${GH_MIRROR:-$(msg mirror.direct)}" "${GH_MIRROR_TYPE}")"
        return 0
    fi
    # SKIP_DEPS 时不下载外部包，跳过测速，直接用直连。
    if [[ "${SKIP_DEPS:-0}" == "1" ]]; then
        GH_MIRROR=""; GH_MIRROR_TYPE="direct"; info "$(msg mirror.skip_deps)"; return 0
    fi
    # 环境变量覆盖：全量代理（系统代理），如 http://127.0.0.1:7890 / socks5://...
    if [[ -n "${SMART_INSTALL_PROXY:-}" ]]; then
        case "${SMART_INSTALL_PROXY}" in
            none|direct|off) : ;;
            *) _apply_full_proxy "${SMART_INSTALL_PROXY}"
               info "$(msg proxy.chosen "${SMART_INSTALL_PROXY}")"
               return 0 ;;
        esac
    fi

    # 外网 IP 归属地检测。三种结果（中国大陆 / 非中国大陆 / 没检测出来）
    # 走同一套流程（测速 -> 推荐 -> 菜单），差别只在“可见候选集合”：
    # 非中国大陆剔除预置镜像（留 direct），另两种保留全部候选。
    info "$(msg region.test)"
    detect_public_ip_region || true
    case "${_PUB_IP_COUNTRY:-UNKNOWN}" in
        CN)
            info "$(msg region.cn "$(_region_display)")" ;;
        OTHER)
            info "$(msg region.foreign "$(_region_display)")"
            info "$(msg region.direct_ok)" ;;
        *)
            warn "$(msg region.unknown)" ;;
    esac
    # 必须在 case 之后调用：地区结果决定谁留在候选池里。
    _build_mirror_pool
    # 当前代理环境变量在三种结果下都打印：用户是否已有代理，与他在哪个地区无关。
    _show_proxy_env

    info "$(msg mirror.test)"
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
            GH_MIRROR_TYPE="${MIRROR_TYPES[$best]}"
            info "$(msg mirror.auto_fastest "${MIRROR_LABELS[$best]}" "${MIRROR_TIMES[$best]}" "${GH_MIRROR_TYPE}")"
        else
            GH_MIRROR=""; GH_MIRROR_TYPE="direct"; warn "$(msg mirror.all_down)"
        fi
        return 0
    fi

    echo
    info "$(msg mirror.select)"
    # 菜单按 MIRROR_ACTIVE（可见候选）连续编号 —— 非中国大陆时预置镜像缺席，
    # 编号必须压紧，否则会留下“选了没反应”的空位。
    local n=${#MIRROR_ACTIVE[@]} ii i d=1
    local fastest_idx=""
    for i in $(mirror_ordered_indices); do
        [[ "${MIRROR_TIMES[$i]}" != "999" ]] && { fastest_idx="$i"; break; }
    done
    [[ -z "$fastest_idx" ]] && fastest_idx=0   # 全部不可用时默认直连
    for (( ii=0; ii<n; ii++ )); do
        local mark=""
        i="${MIRROR_ACTIVE[$ii]}"
        [[ "$i" == "$fastest_idx" ]] && mark=" (推荐)"
        printf "  %2d) %s%s  [%ss]\n" "$d" "${MIRROR_LABELS[$i]}" "$mark" "${MIRROR_TIMES[$i]}"
        d=$((d+1))
    done
    printf "  %2d) %s\n" "$d" "$(msg mirror.manual)"
    local custom_d=$d; d=$((d+1))
    printf "  %2d) %s\n" "$d" "$(msg mirror.manual_proxy)"
    local custom_proxy_d=$d
    local choice="" REPLY=""
    # 默认项要按“菜单序号”给，不是按候选索引 —— 两者在隐藏了预置镜像后不再相等。
    local default_d=1 p
    for (( p=0; p<n; p++ )); do
        [[ "${MIRROR_ACTIVE[$p]}" == "$fastest_idx" ]] && { default_d=$((p+1)); break; }
    done
    echo -n "$(msg mirror.prompt "$default_d")"
    while true; do
        _tty_read -r REPLY || REPLY=""
        if [[ -z "$REPLY" ]]; then
            choice=$fastest_idx; break
        elif [[ "$REPLY" =~ ^[0-9]+$ ]]; then
            if (( REPLY >= 1 && REPLY <= n )); then
                choice=${MIRROR_ACTIVE[$((REPLY-1))]}; break
            elif (( REPLY == custom_d )); then
                echo -n "  请输入镜像前缀 URL（如 https://ghproxy.net/ ）或域名替换主机: "
                _tty_read -r GH_MIRROR || GH_MIRROR=""
                GH_MIRROR_TYPE="$(_guess_mirror_type "$GH_MIRROR")"
                if [[ "$GH_MIRROR_TYPE" == "prefix" && "$GH_MIRROR" != */ ]]; then
                    GH_MIRROR="${GH_MIRROR}/"
                fi
                info "$(msg mirror.custom_chosen2 "$GH_MIRROR" "$GH_MIRROR_TYPE")"
                return 0
            elif (( REPLY == custom_proxy_d )); then
                if _manual_proxy_flow; then return 0; fi
                # 用户取消：回到菜单重新选择
                echo -n "$(msg mirror.prompt "$default_d")"; continue
            else
                echo -n "  无效序号，请重新输入 [默认=${default_d}]: "; continue
            fi
        else
            echo -n "  无效输入，请输入序号 [默认=${default_d}]: "; continue
        fi
    done
    GH_MIRROR="${MIRROR_PREFIXES[$choice]}"
    GH_MIRROR_TYPE="${MIRROR_TYPES[$choice]}"
    info "$(msg mirror.chosen "${MIRROR_LABELS[$choice]}" "${MIRROR_TIMES[$choice]}" "$GH_MIRROR_TYPE")"
}

# Curl with sane defaults; GitHub / raw URLs are rewritten through the chosen mirror.
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
    local dir="$1" prefix="$2" type="${3:-prefix}"
    # shim 在子进程中运行，无法直接调用主脚本函数，故内联一份与 _rewrite_with
    # 完全同构的重写逻辑（务必与 _rewrite_with 保持同步）。
    cat > "$dir/_zsc_rw.sh" <<RWE
#!/usr/bin/env bash
PREFIX='$prefix'
_zsc_rw() {
  local url="\$1"
  [[ -z "\$PREFIX" ]] && { echo "\$url"; return 0; }
  case '$type' in
    prefix)
      case "\$url" in
        https://github.com/*|https://raw.githubusercontent.com/*) echo "\$PREFIX\$url" ;;
        *) echo "\$url" ;;
      esac ;;
    domain)
      case "\$url" in
        https://github.com/*) echo "\${url/github.com/\$PREFIX}" ;;
        *) echo "\$url" ;;
      esac ;;
    clone)
      # 文件下载（releases/raw 等）必须直连，只有仓库地址才走加速
      case "\$url" in
        */releases/*|*/archive/*|https://raw.githubusercontent.com/*|*objects.githubusercontent.com*) echo "\$url" ;;
        https://github.com/*) echo "\${PREFIX}github.com/\${url#https://github.com/}" ;;
        *) echo "\$url" ;;
      esac ;;
    *) echo "\$url" ;;
  esac
}
RWE
    cat > "$dir/curl" <<SHIM
#!/usr/bin/env bash
source "\$(dirname "\$0")/_zsc_rw.sh" 2>/dev/null || true
args=("\$@")
for i in "\${!args[@]}"; do
  args[\$i]="\$(_zsc_rw "\${args[\$i]}")"
done
exec '$REAL_CURL' "\${args[@]}"
SHIM
    if [[ -n "$REAL_WGET" ]]; then
        cat > "$dir/wget" <<SHIM
#!/usr/bin/env bash
source "\$(dirname "\$0")/_zsc_rw.sh" 2>/dev/null || true
args=("\$@")
for i in "\${!args[@]}"; do
  args[\$i]="\$(_zsc_rw "\${args[\$i]}")"
done
exec '$REAL_WGET' "\${args[@]}"
SHIM
    fi
    chmod +x "$dir/curl" "$dir/wget" 2>/dev/null || true
}

# 在镜像加速的 curl/wget shim 环境下运行命令（用于 starship / atuin 安装）。
run_with_mirror_dl() {
    local cmd="$1"
    if [[ -z "$GH_MIRROR" || "${GH_MIRROR_TYPE:-direct}" == "direct" ]]; then
        eval "$cmd" || return $?
        return 0
    fi
    # 全量代理：URL 无需改写，代理已由 HTTP_PROXY/HTTPS_PROXY 导出，
    # curl/git/wget 会透明使用。失败时临时撤掉代理再直连重试一次。
    if [[ "${GH_MIRROR_TYPE}" == "proxy" ]]; then
        local prc=0
        eval "$cmd" || prc=$?
        if (( prc != 0 )); then
            warn "$(msg dl.proxy_failed "$prc")"
            prc=0
            ( unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
              eval "$cmd" ) || prc=$?
            if (( prc == 0 )); then success "$(msg dl.direct_ok2)"; fi
        fi
        return $prc
    fi
    local shimdir; shimdir="$(mktemp -d)"
    _mk_dl_shim "$shimdir" "$GH_MIRROR" "$GH_MIRROR_TYPE"
    local oldpath="$PATH"
    PATH="$shimdir:$PATH"
    # 用 `|| rc=$?` 捕获：set -e 下 eval 失败会直接中止脚本，
    # 那样既拿不到返回码，也不会执行下面的直连回退。
    local rc=0
    eval "$cmd" || rc=$?
    PATH="$oldpath"
    rm -rf "$shimdir"
    if (( rc != 0 )); then
        warn "$(msg dl.mirror_failed2 "$rc")"
        # 必须先归零：成功时 `||` 会短路，否则会沿用镜像失败时的 rc
        rc=0
        eval "$cmd" || rc=$?
        if (( rc == 0 )); then
            success "$(msg dl.direct_ok2)"
        fi
    fi
    return $rc
}

# git clone 仓库：先走镜像，失败则回退直连（镜像不支持该地址形态时不会卡死）。
git_clone_repo() {
    local src="$1" dest="$2"
    local m; m="$(mirror_rewrite "$src")"
    if git clone --depth 1 "$m" "$dest" 2>/dev/null; then
        return 0
    fi
    if [[ "$m" != "$src" ]]; then
        warn "$(msg dl.clone_fallback "$src")"
        rm -rf "$dest" 2>/dev/null || true
        git clone --depth 1 "$src" "$dest" 2>/dev/null && return 0
    fi
    return 1
}

select_language

# ------------------------------------------------------------------
# 1. Detect Entware / opkg
# ------------------------------------------------------------------
OPKG=""
if command -v opkg >/dev/null 2>&1; then
    OPKG="$(command -v opkg)"
elif [[ -x /opt/bin/opkg ]]; then
    OPKG="/opt/bin/opkg"
fi
[[ -n "$OPKG" ]] || error "$(msg e.opkg_not_found)"

info "$(msg i.entware_detected "$OPKG")"
info "$(msg i.home_dir "$HOME")"

# Select a GitHub acceleration mirror up front so every clone / raw download
# below can use it. Honors SMART_INSTALL_GH_MIRROR and NONINTERACTIVE.
select_mirror

if [[ "$(id -u)" != "0" ]]; then
    warn "$(msg w.not_root "$(id -u)")"
fi

# ------------------------------------------------------------------
# 2. Install Zsh (no sudo under Entware)
# ------------------------------------------------------------------
info "$(msg phase1)"

# Check Zsh; if missing, guide the user and install it via opkg.
check_zsh() {
    ZSH_BIN=""
    if command -v zsh >/dev/null 2>&1; then
        ZSH_BIN="$(command -v zsh)"
        success "$(msg msg.zsh_installed "$(zsh --version 2>/dev/null | head -n 1)") -> $ZSH_BIN"
        return 0
    fi
    warn "$(msg w.zsh_missing_entware)"
    if [[ -z "$OPKG" ]]; then
        error "$(msg e.opkg_missing_zsh)"
    fi
    info "$(msg i.installing_zsh_opkg)"
    "$OPKG" install zsh || error "$(msg e.opkg_install_zsh_failed)"
    ZSH_BIN="$(command -v zsh)"
    [[ -n "$ZSH_BIN" ]] || ZSH_BIN="/opt/bin/zsh"
    success "$(msg s.zsh_installed_at "$ZSH_BIN")"
    info "$(msg i.zsh_done_relogin "$ZSH_BIN")"
    return 0
}
check_zsh

# Set the login shell. Entware has no /etc/shells + chsh.
info "$(msg i.switching_login_shell)"
PROFILE_FILE="$HOME/.profile"
# Marker comment makes the guard idempotent and unambiguous.
if ! grep -q "zsh-smart-complete: prefer zsh" "$PROFILE_FILE" 2>/dev/null; then
    cat >> "$PROFILE_FILE" <<PROF

# --- zsh-smart-complete: prefer zsh over the default ash/bash ---
if [ -x "$ZSH_BIN" ] && [ -z "\$ZSH_RUNNING" ]; then
    export ZSH_RUNNING=1
    exec "$ZSH_BIN"
fi
PROF
    success "$(msg s.profile_launch_added "$ZSH_BIN" "$PROFILE_FILE")"
    warn "$(msg w.qnap_gui_hint)"
else
    info "$(msg i.profile_already_zsh "$PROFILE_FILE")"
fi

# Optional fzf (the plugin core works without it). Try opkg, then fall back to
# the official git-clone install (mirror-accelerated).
if [[ "${SKIP_DEPS:-0}" != "1" ]] && prompt_yes "$(msg q.install_fzf)" 0; then
    if command -v fzf >/dev/null 2>&1; then
        success "$(msg s.fzf_already)"
    elif "$OPKG" install fzf 2>/dev/null; then
        success "$(msg s.fzf_installed_opkg)"
    else
        warn "$(msg i.fzf_not_in_feed)"
        fzf_dir="${XDG_DATA_HOME:-$HOME/.local/share}/fzf"
        if git_clone_repo "https://github.com/junegunn/fzf.git" "$fzf_dir" \
           && ( cd "$fzf_dir" && "$fzf_dir/install" --all >/dev/null 2>&1 ); then
            success "$(msg s.fzf_installed_git)"
        else
            warn "$(msg w.fzf_install_failed_entware)"
        fi
    fi
fi

# ------------------------------------------------------------------
# 3. Optional Starship prompt
# ------------------------------------------------------------------
info "$(msg phase2)"
if command -v starship >/dev/null 2>&1; then
    success "$(msg s.starship_present2 "$(starship --version 2>/dev/null || echo present)")"
elif [[ "${SKIP_DEPS:-0}" != "1" ]] && prompt_yes "$(msg prompt.starship)" 0; then
    info "$(msg i.trying_opkg_starship)"
    if "$OPKG" install starship 2>/dev/null; then
        success "$(msg s.starship_installed)"
        STARSHIP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
        STARSHIP_CONFIG_FILE="${STARSHIP_CONFIG_DIR}/starship.toml"
        mkdir -p "$STARSHIP_CONFIG_DIR"
# Does this config already carry the recommended two-line layout? The marker
# exists in templates/starship.toml.example and in no stock Starship install.
_starship_cfg_is_recommended() {
    grep -qF 'success_symbol = "[:> ](bold green)"' "$1" 2>/dev/null
}

# Does it define ANY layout? Without a `format` key starship silently renders
# its own DEFAULT prompt, whatever else the file says.
_starship_cfg_has_layout() {
    grep -qE '^[[:space:]]*format[[:space:]]*=' "$1" 2>/dev/null
}

# _starship_cfg_decide <file> -> missing | recommended | legacy | custom
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

_write_recommended_starship() {
    cat > "$STARSHIP_CONFIG_FILE" <<'TOML'
# Recommended Starship Prompt Config for zsh-smart-complete
# Two-line prompt:
#   line 1 = USER (with icon) + current directory
#   line 2 = ":>" symbol, where input starts
# Host / git / language versions are intentionally omitted.
#
# Install Starship: https://starship.rs/guide/#%F0%9F%9A%80-installation
# In .zshrc:   eval "$(starship init zsh)"

add_newline = false

# NOTE: top-level keys MUST come before any [section] header,
# otherwise TOML nests them under the previous table and starship ignores them.
# The literal newline splits the info line from the input line.
format = """
$username › $directory
$character"""

# User - icon + name, green (red for root)
[username]
show_always = true
style_user = "bold green"
style_root = "bold red"
format = "[ $user]($style)"

# Hostname - never shown
[hostname]
disabled = true

# Current directory - cyan, up to 3 parents
[directory]
truncation_length = 3
truncation_symbol = "…/"
style = "bold cyan"
truncate_to_repo = false
format = "[$path]($style)"

# Prompt symbol ":>" on the 2nd line - green on success, red on error
[character]
success_symbol = "[:> ](bold green)"
error_symbol   = "[:> ](bold red)"
TOML
}

        # One source of truth: this heredoc is what a `curl … | bash` install of
        # THIS installer writes (there is no templates/ directory then), so it
        # must stay byte-identical to templates/starship.toml.example — enforced
        # by tests/test-installer-options.sh. It drifted once before (see the
        # "prompt reverted to the Starship default" bug).
        case "$(_starship_cfg_decide "$STARSHIP_CONFIG_FILE")" in
            missing)
                _write_recommended_starship
                success "$(msg s.starship_cfg_written "$STARSHIP_CONFIG_FILE")"
                ;;
            recommended)
                info "$(msg i.starship_cfg_ok "$STARSHIP_CONFIG_FILE")"
                ;;
            legacy)
                warn "$(msg w.starship_cfg_legacy "$STARSHIP_CONFIG_FILE")"
                cp -f "$STARSHIP_CONFIG_FILE" "${STARSHIP_CONFIG_FILE}.bak.$(date +%s)"
                _write_recommended_starship
                success "$(msg s.starship_cfg_repaired "$STARSHIP_CONFIG_FILE")"
                ;;
            *)
                info "$(msg w.starship_cfg_exists "$STARSHIP_CONFIG_FILE")"
                if prompt_yes "$(msg q.overwrite_starship)" 1; then
                    cp -f "$STARSHIP_CONFIG_FILE" "${STARSHIP_CONFIG_FILE}.bak.$(date +%s)"
                    _write_recommended_starship
                    success "$(msg s.starship_cfg_updated)"
                fi
                ;;
        esac
    else
        info "$(msg i.opkg_no_starship)"
        if run_with_mirror_dl 'curl -fsSL https://starship.rs/install.sh | sh -s -- -y' 2>/dev/null; then
            success "$(msg s.starship_official_installed)"
        else
            warn "$(msg w.starship_install_failed_soft)"
        fi
    fi
fi

# ------------------------------------------------------------------
# 3b. Optional Atuin (shell-history sync/search)
# ------------------------------------------------------------------
info "$(msg phase2b)"
if command -v atuin >/dev/null 2>&1; then
    success "$(msg s.atuin_present "$(atuin --version 2>/dev/null || echo present)")"
elif [[ "${SKIP_DEPS:-0}" != "1" ]] && prompt_yes "$(msg prompt.atuin)" 0; then
    # 外层脚本抓取与“内层”从 GitHub Releases 下载的二进制均经镜像 shim 加速。
    info "$(msg i.atuin_official_binary)"
    if run_with_mirror_dl 'curl -fsSL https://setup.atuin.sh | sh -s -- --non-interactive 2>/dev/null'; then
        success "$(msg s.atuin_installed)"
    else
        warn "$(msg w.atuin_failed_entware)"
    fi
fi

# ------------------------------------------------------------------
# 4. Zinit plugin manager + plugin clone
# ------------------------------------------------------------------
info "$(msg phase3)"
ZINIT_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/zinit.git"

if [[ -d "$ZINIT_HOME" ]]; then
    success "$(msg s.zinit_installed_path "$ZINIT_HOME")"
    if prompt_yes "$(msg prompt.zinit_pull)" 0; then
        ( cd "$ZINIT_HOME" && git pull --ff-only 2>/dev/null ) || warn "$(msg w.git_pull_failed)"
    fi
elif [[ "${SKIP_DEPS:-0}" != "1" ]] && prompt_yes "$(msg prompt.zinit)" 1; then
    mkdir -p "$(dirname "$ZINIT_HOME")"
    git_clone_repo "https://github.com/zdharma-continuum/zinit.git" "$ZINIT_HOME" \
        || error "$(msg e.zinit_clone_failed)"
    success "$(msg s.zinit_installed)"
fi

SMART_COMPLETE_INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/plugins/imonior---zsh-smart-complete"
if [[ ! -d "$SMART_COMPLETE_INSTALL_DIR" && "${SKIP_DEPS:-0}" != "1" ]]; then
    info "$(msg i.cloning_plugin)"
    mkdir -p "$(dirname "$SMART_COMPLETE_INSTALL_DIR")"
    git_clone_repo "https://github.com/imonior/zsh-smart-complete.git" "$SMART_COMPLETE_INSTALL_DIR" \
        || warn "$(msg w.entware_clone_failed)"
fi

# ------------------------------------------------------------------
# Conflict cleanup
# ------------------------------------------------------------------
info "$(msg phase.cleanup)"
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
        success "$(msg s.commented_lines "$pattern")"
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
            # Skip backups a previous run kept (e.g. zsh-autocomplete.bak.<ts>):
            # they are not active plugins, so must NOT be re-reported as conflicts.
            [[ "$(basename "$pdir")" == *.bak.* ]] && continue
            found=1; warn "$(msg w.conflict_plugin_dir "$pdir")"
        done
    fi
    omz_dir="$HOME/.oh-my-zsh/custom/plugins/$plugin_name"
    if [[ -d "$omz_dir" ]]; then found=1; warn "$(msg w.conflict_plugin_dir "$omz_dir")"; fi
    if [[ -f "$HOME/.zshrc" ]]; then
        matches="$(grep -nF "$plugin_name" "$HOME/.zshrc" 2>/dev/null | grep -v '^[[:space:]]*#' || true)"
        [[ -n "$matches" ]] && found=1
    fi
    if (( found == 0 )); then
        success "$(msg s.no_conflict "$plugin_name")"
        return 0
    fi
    if prompt_yes "$(msg prompt.remove_plugin "$plugin_name")" 1; then
        comment_out_zshrc "$plugin_name"
        if [[ -d "$ZINIT_PLUGINS_DIR" ]]; then
            for pdir in "$ZINIT_PLUGINS_DIR"/*"$plugin_name"*; do
                [[ -d "$pdir" ]] || continue
                mv "$pdir" "${pdir}.bak.$(date +%s)" && success "$(msg s.backed_up_removed_path "$pdir")"
            done
        fi
        if [[ -d "$omz_dir" ]]; then
            mv "$omz_dir" "${omz_dir}.bak.$(date +%s)" && success "$(msg s.backed_up_removed_path "$omz_dir")"
        fi
    else
        warn "$(msg w.skipped_removal_1 "$plugin_name")"
    fi
}

# Config combo: zinit-starship (recommended) | keep-omz | zinit-p10k
CONFIG_COMBO="zinit-starship"

# Read-only advisory scan for conflicting plugin loaders living in STARTUP
# FILES OTHER THAN ~/.zshrc.
#
# Why this exists: zsh-smart-complete's conflict cleanup only edits ~/.zshrc
# (per the documented cleanup scope — we deliberately do NOT expand the
# automatic edit to other files, to avoid touching config the user manages
# elsewhere). But zsh-autocomplete / zsh-autosuggestions loaders are sometimes
# placed in .zprofile, .zshenv, conf.d/*.zsh, .zshrc.d/* or /etc/zsh/zshrc. If a
# loader survives there, the plugin keeps loading on every `exec zsh` and
# re-triggers the duplicate-suggestion / Tab-conflict symptom.
#
# NOTE: fzf-tab is intentionally NOT flagged here. As of v2.2.4 it is a SUPPORTED
# alternative list-drawer (SMART_MENU_LISTER=fzf-tab), so its presence is
# expected/intended, not a conflict. Only the two autocomplete-style plugins are
# pure duplicates of what zsh-smart-complete already provides.
#
# This function scans those files and WARNS the user with the exact file:line,
# so they can clean it manually. It NEVER modifies any file.
_scan_other_rcs() {
    local zdir="${ZDOTDIR:-$HOME}"
    local pat='zsh-autocomplete|zsh-autosuggestions'
    local -a files=()
    local f ml hit=0
    files+=("$zdir/.zprofile" "$zdir/.zshenv" "$zdir/.zlogin")
    files+=("$zdir/conf.d"/*.zsh "$zdir/.zshrc.d"/*.zsh)
    files+=("/etc/zsh/zshrc")
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        # .zshrc is owned by clean_conflict_plugin; never double-report it.
        [[ "$(basename "$f")" == ".zshrc" ]] && continue
        while IFS= read -r ml; do
            (( hit )) || warn "$(msg cleanup.scan_other_rcs_head)"
            hit=1
            warn "$(msg cleanup.scan_other_rcs_line "$f" "$ml")"
        done < <(grep -nE "$pat" "$f" 2>/dev/null | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*#')
    done
    if (( hit )); then
        warn "$(msg cleanup.scan_other_rcs_hint)"
    else
        success "$(msg cleanup.scan_other_rcs_clean)"
    fi
}

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
    if [[ -d "$HOME/.oh-my-zsh" ]] && prompt_yes "$(msg q.del_omz)" 0; then
        mv "$HOME/.oh-my-zsh" "$HOME/.oh-my-zsh.bak.$(date +%s)" && success "$(msg s.backed_up_removed_omz)"
    fi
}
_remove_p10k() {
    comment_out_zshrc 'powerlevel10k'
    comment_out_zshrc 'p10k.zsh'
    if [[ -f "$HOME/.p10k.zsh" ]] && prompt_yes "$(msg q.del_p10k)" 0; then
        mv "$HOME/.p10k.zsh" "$HOME/.p10k.zsh.bak.$(date +%s)" && success "$(msg s.backed_up_removed_p10k)"
    fi
    if [[ -d "$HOME/.powerlevel10k" ]] && prompt_yes "$(msg q.del_p10k_dir)" 0; then
        mv "$HOME/.powerlevel10k" "$HOME/.powerlevel10k.bak.$(date +%s)" && success "$(msg s.removed_p10k_dir)"
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
        mv -f "$tmp" "$f" 2>/dev/null || warn "$(msg w.zsh_theme_write_failed "$f" "$theme")"
        success "$(msg s.zsh_theme_set "$theme")"
    else
        printf 'ZSH_THEME="%s"\n' "$theme" >> "$f"
        success "$(msg s.zsh_theme_appended "$theme" "$f")"
    fi
    return 0
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
    local omz_url="$(mirror_rewrite "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh")"
    if run_with_mirror_dl "sh -c \"\$(curl -fsSL ${omz_url})\" '' --unattended" 2>/dev/null; then
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

_apply_combo() {
    CONFIG_COMBO="$1"
    case "$CONFIG_COMBO" in
        keep-omz)
            info "$(msg i.combo_kept_omz_p10k)"
            _ensure_omz
            _ensure_p10k_omz ;;
        zinit-p10k)
            info "$(msg i.combo_zinit_p10k)"
            _remove_omz
            _ensure_p10k_zinit ;;
        zinit-starship)
            info "$(msg i.combo_recommended)"
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
                info "$(msg combo.env "${SMART_INSTALL_COMBO}")"
                return 0 ;;
            *) warn "$(msg combo.unknown_env "$SMART_INSTALL_COMBO")" ;;
        esac
    fi
    if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
        _apply_combo "zinit-starship"
        info "$(msg combo.headless_auto)"
        return 0
    fi

    # 无论是否已安装 OMZ/p10k，都给出组合选择；全部未安装时推荐 Zinit+Starship，
    # 同时分别提供 Oh My Zsh / Powerlevel10k 备选。
    echo
    info "$(msg combo.prompt)"
    if (( HAS_OMZ == 0 && HAS_P10K == 0 )); then
        printf "  1) (推荐) Zinit + Starship —— 全新安装，轻量现代\n"
        printf "  2) Oh My Zsh + Powerlevel10k —— 经典方案（将为你安装 OMZ 与 p10k）\n"
        printf "  3) Zinit + Powerlevel10k —— Zinit 管理 p10k 主题\n"
    else
        local msg=""
        (( HAS_OMZ )) && msg+=" Oh My Zsh" || true
        (( HAS_P10K )) && msg+=" Powerlevel10k" || true
        info "$(msg combo.detected_installed "$msg")"
        printf "  1) (推荐) 移除 OMZ/p10k，全新 Zinit + Starship\n"
        printf "  2) 保留 OMZ + p10k，配合使用\n"
        printf "  3) 移除 OMZ，保留 p10k（Zinit + Powerlevel10k）\n"
    fi
    echo -n "输入序号 [默认=1]: "
    local REPLY
    _tty_read -r REPLY || true
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
# Read-only advisory: warn (do NOT edit) about loaders in OTHER startup files
# that clean_conflict_plugin does not reach, so the user can clean them manually.
_scan_other_rcs
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
            PROMPT_INIT_SNIPPET='command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"' ;;
    esac
}
zsc_prompt_snippet


# Entware has no `_ensure_zinit_plugin` (this is a different, leaner installer),
# so the opt-in plugins are cloned into the standard Zinit plugins directory
# here. Both calls are non-fatal: Zinit would fetch the plugin on first shell
# start anyway.
_entware_ensure_zinit_plugin() {
    local slug="$1"
    local name="${slug//\//---}"
    local dir="${ZINIT_PLUGINS_DIR}/${name}"
    if [[ -d "$dir/.git" ]]; then
        ( cd "$dir" && git pull --ff-only 2>/dev/null ) \
            || warn "$(msg w.plugin_update_skipped "$slug")"
    elif [[ ! -d "$dir" ]]; then
        mkdir -p "$(dirname "$dir")"
        git_clone_repo "https://github.com/${slug}.git" "$dir" \
            || warn "$(msg w.zinit_dep_clone_failed "$slug")"
    fi
    return 0
}

# ------------------------------------------------------------------
# Optional components & settings — ASKED, then WRITTEN INTO ~/.zshrc
# ------------------------------------------------------------------
# Every optional piece of the generated ~/.zshrc is a question, and the answers
# are baked into a managed block as explicit `export`s. Two reasons this is
# worth the extra prompts:
#
#   1. Nothing is enabled behind the user's back, and nothing has to be
#      discovered in a doc afterwards — the generated config IS the transcript
#      of the answers.
#   2. A second completion LISTER is the classic cause of "two popups on screen
#      at once". fzf-tab draws its own floating list, so it is an explicit
#      OPT-IN (default: no); when it IS enabled we force the built-in
#      selectable Tab menu off, because running both is precisely how two
#      listers end up fighting over the same screen area.
#
# NONINTERACTIVE=1 takes every documented default, which reproduces the
# historical recommended config.
ZSC_OPT_MENU=1              # type-to-popup                        (default on)
ZSC_OPT_SINGLE_COLUMN=0     # vertical list, one candidate a line  (default OFF)
ZSC_OPT_RECENT_PATHS=1      # `cd ` lists recent directories       (default on)
ZSC_OPT_HISTORY_KEYS=0      # Up/Down prefix-search history        (default off)
ZSC_OPT_NATIVE_MENU=1       # Tab opens a selectable menu          (default ON)
ZSC_OPT_FZF_TAB=0           # fzf-tab: its own floating list       (default off)
ZSC_OPT_VIMODE=0            # zsh-vi-mode                          (default off)
ZSC_OPT_STRATEGY="history,completion"  # inline suggestion source (default: history first, completion fills gaps)

_zsc_bool() { if [[ "$1" == "1" ]]; then printf 'true'; else printf 'false'; fi; }

ask_smart_options() {
    echo
    info "$(msg opt.title)"
    echo

    if prompt_yes "$(msg opt.menu)" 1; then ZSC_OPT_MENU=1; else ZSC_OPT_MENU=0; fi
    # Default NO on purpose: a single-column list is generated by the plugin
    # rather than taken from compsys, so it loses descriptions / colours / fuzzy
    # matching for those contexts and hands every other context back to the
    # native grid. It is a look, not an upgrade — so the user opts in.
    if prompt_yes "$(msg opt.single_column)" 0; then ZSC_OPT_SINGLE_COLUMN=1; else ZSC_OPT_SINGLE_COLUMN=0; fi
    if prompt_yes "$(msg opt.recent_paths)" 1; then ZSC_OPT_RECENT_PATHS=1; else ZSC_OPT_RECENT_PATHS=0; fi
    if prompt_yes "$(msg opt.history_keys)" 0; then ZSC_OPT_HISTORY_KEYS=1; else ZSC_OPT_HISTORY_KEYS=0; fi

    warn "$(msg opt.fzf_warn)"
    if prompt_yes "$(msg opt.fzf_tab)" 0; then ZSC_OPT_FZF_TAB=1; else ZSC_OPT_FZF_TAB=0; fi

    # Only ask about the Tab menu when a second lister is not already taking
    # over Tab — with fzf-tab installed the answer would be meaningless.
    if (( ZSC_OPT_FZF_TAB )); then
        ZSC_OPT_NATIVE_MENU=0
    else
        # NOTE the default is YES: lib/config.zsh ships
        # SMART_NATIVE_MENU_SELECT=true, and a non-interactive install must not
        # silently change the shipped behaviour.
        if prompt_yes "$(msg opt.native_menu)" 1; then ZSC_OPT_NATIVE_MENU=1; else ZSC_OPT_NATIVE_MENU=0; fi
    fi

    if prompt_yes "$(msg opt.vimode)" 0; then ZSC_OPT_VIMODE=1; else ZSC_OPT_VIMODE=0; fi

    # Suggestion source. A numbered menu rather than y/n because there are three
    # documented values of SMART_SUGGEST_STRATEGY, and choosing wrongly is
    # invisible until a suggestion that should have appeared does not.
    # DEFAULT = history,completion: history alone leaves a feedback vacuum when
    # typing a path halfway that was never run before — the "no hint at /u but
    # a hint at /usr/" report.
    if [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
        local REPLY=""
        echo
        echo "  $(msg opt.strategy_prompt)"
        printf "    1) %s\n" "$(msg opt.strategy_both)"
        printf "    2) %s\n" "$(msg opt.strategy_history)"
        printf "    3) %s\n" "$(msg opt.strategy_completion)"
        echo -n "  > "
        _tty_read -r REPLY || REPLY=""
        case "$REPLY" in
            2) ZSC_OPT_STRATEGY="history" ;;
            3) ZSC_OPT_STRATEGY="completion" ;;
            *) ZSC_OPT_STRATEGY="history,completion" ;;
        esac
    fi
    return 0
}

ask_smart_options

# Install the opt-in plugins only AFTER the questions, so nothing is cloned for
# a component the user declined.
ZSC_VIMODE_SNIPPET=""
if (( ZSC_OPT_VIMODE )); then
    info "$(msg i.installing_vimode)"
    _entware_ensure_zinit_plugin "jeffreytse/zsh-vi-mode"
    ZSC_VIMODE_SNIPPET='    # --- zsh-vi-mode (opt-in) ---
    # vi-mode owns the keymaps and re-initialises ZLE on every line-init, so
    # anything bound before it gets clobbered. Load it first, then let it call
    # us back and re-apply the zsh-smart-complete widgets.
    zinit ice wait lucid
    zinit light jeffreytse/zsh-vi-mode
    zvm_after_init() { smart-enable 2>/dev/null }
    zvm_after_lazy_keybindings() { smart-enable 2>/dev/null }'
fi
if (( ZSC_OPT_FZF_TAB )); then
    info "$(msg i.installing_fzftab)"
    _entware_ensure_zinit_plugin "Aloxaf/fzf-tab"
    if ! command -v fzf >/dev/null 2>&1; then
        warn "$(msg w.fzftab_needs_fzf)"
    fi
fi

# Same idea for the OPTIONS block (see build_smart_options below). It is kept
# separate from the loader block because it has to sit ABOVE the plugin load:
# a few options are read while the plugin installs its key bindings.
OPT_BLOCK_BEGIN="# >>> zsh-smart-complete options (managed) >>>"
OPT_BLOCK_END="# <<< zsh-smart-complete options <<<"

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

# ------------------------------------------------------------------
# 5. Configure ~/.zshrc
# ------------------------------------------------------------------
info "$(msg phase4)"
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
    info "$(msg i.no_zshrc_creating)"
    cat > "$ZSHRC_FILE" <<'ZRCEOF'
export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=1000000
export SAVEHIST=1000000
setopt appendhistory sharehistory histignorealldups
autoload -Uz compinit
compinit -d "${ZDOTDIR:-$HOME}/.zcompdump"
ZRCEOF
    # Options go in BEFORE the loader block: a few of them are read while the
    # plugin installs its key bindings, so writing them afterwards would be
    # silently ignored.
    _upsert_options_block "$ZSHRC_FILE" "$(build_smart_options)"
    printf '%s\n' "$(build_zsc_integration)" >> "$ZSHRC_FILE"
    success "$(msg s.zshrc_created_with_block "$ZSHRC_FILE")"
elif grep -q "zsh-smart-complete" "$ZSHRC_FILE"; then
    # The loader is already there, so we leave it alone — but still refresh OUR
    # managed options block, which is the only way to change the answers on a
    # re-run without hand-editing the file.
    cp -f "$ZSHRC_FILE" "${ZSHRC_FILE}.bak.$(date +%s)"
    _upsert_options_block "$ZSHRC_FILE" "$(build_smart_options)"
    success "$(msg s.zshrc_updated_backup "$ZSHRC_FILE")"
else
    if prompt_yes "$(msg q.append_block)" 1; then
        cp -f "$ZSHRC_FILE" "${ZSHRC_FILE}.bak.$(date +%s)"
        _upsert_options_block "$ZSHRC_FILE" "$(build_smart_options)"
        printf '\n%s\n' "$(build_zsc_integration)" >> "$ZSHRC_FILE"
        success "$(msg s.zshrc_file_updated "$ZSHRC_FILE")"
    fi
fi

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
            print -r -- "# zsh-smart-complete — user settings"
            print -r -- "# Run \`zsc-settings\` (if installed) or edit a value below; restart zsh after changes."
            print -r -- "# Lines starting with # are ignored."
            print -r -- "#"
            print -r -- "# SMART_SUGGEST_COLOR=auto"
            print -r -- "# SMART_MENU=true"
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
_install_user_settings

# ------------------------------------------------------------------
# Final banner
# ------------------------------------------------------------------
echo
echo "============================================================"
echo -e "${GREEN}  🎉 zsh-smart-complete (Entware) installer finished${NC}"
echo "============================================================"
echo
echo "Reload your shell with:  exec $ZSH_BIN"
echo "(new SSH login will auto-launch zsh via $PROFILE_FILE)"
echo
echo "Then try:"
echo "  git s  [Tab]   → native completion (menu)"
echo "  git s  [→]     → inline suggestion accept"
echo "  git s  [↑]     → native history navigation"
echo
