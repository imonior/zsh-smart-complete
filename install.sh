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

# Ensure interactive prompts work over SSH (non-tty stdin returns immediately)
_setup_terminal() {
    [[ -t 0 ]] || return 0
    stty sane 2>/dev/null || true
}
_setup_terminal

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
                zh-CN) s="请选择 GitHub 加速镜像（已列出全部候选的测速结果）：" ;;
                zh-TW) s="請選擇 GitHub 加速鏡像（已列出全部候選的測速結果）：" ;;
                ja)    s="GitHub ミラーを選択してください（全候補の実測値を表示）：" ;;
                ko)    s="GitHub 미러를 선택하세요 (모든 후보의 측정 결과 표시):" ;;
                *)     s="Select a GitHub mirror (all candidates with measured latency):" ;;
            esac ;;
        mirror.manual)
            case "$lang" in
                zh-CN) s="手动输入自定义镜像前缀 URL" ;; zh-TW) s="手動輸入自訂鏡像前綴 URL" ;;
                ja)    s="カスタムミラープレフィックス URL を手動入力" ;;
                ko)    s="사용자 지정 미러 접두사 URL 직접 입력" ;;
                *)     s="Enter a custom mirror prefix URL" ;;
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
        mirror.auto_selected)
            case "$lang" in
                zh-CN) s="已自动选择最快镜像：%s (%ss) [%s]" ;; zh-TW) s="已自動選擇最快鏡像：%s (%ss) [%s]" ;;
                ja)    s="最速ミラーを自動選択: %s (%ss) [%s]" ;;
                ko)    s="최신 미러 자동 선택: %s (%ss) [%s]" ;;
                *)     s="Auto-selected fastest mirror: %s (%ss) [%s]" ;;
            esac ;;
        mirror.all_unavailable)
            case "$lang" in
                zh-CN) s="所有镜像均不可用，回退到直连。" ;; zh-TW) s="所有鏡像均不可用，回退到直連。" ;;
                ja)    s="すべてのミラーが利用不可。ダイレクト接続にフォールバックします。" ;;
                ko)    s="모든 미러를 사용할 수 없습니다. 다이렉트 연결로 폴백합니다." ;;
                *)     s="All mirrors unavailable, falling back to direct connection." ;;
            esac ;;
        mirror.label_direct)
            case "$lang" in
                zh-CN) s="直连（不使用加速）" ;; zh-TW) s="直連（不使用加速）" ;;
                ja)    s="ダイレクト接続（アクセラレーション不使用）" ;;
                ko)    s="직접 연결 (가속 없음)" ;;
                *)     s="Direct (no acceleration)" ;;
            esac ;;
        mirror.label_ghproxy_net)
            case "$lang" in
                zh-CN) s="ghproxy.net (URL 前缀代理)" ;; zh-TW) s="ghproxy.net (URL 前綴代理)" ;;
                ja)    s="ghproxy.net (URL プレフィックスプロキシ)" ;;
                ko)    s="ghproxy.net (URL接두사 프록시)" ;;
                *)     s="ghproxy.net (URL prefix proxy)" ;;
            esac ;;
        mirror.label_ghproxy_com)
            case "$lang" in
                zh-CN) s="ghproxy.com (URL 前缀代理)" ;; zh-TW) s="ghproxy.com (URL 前綴代理)" ;;
                ja)    s="ghproxy.com (URL プレ피ックス프로시)" ;;
                ko)    s="ghproxy.com (URL接두사 프록시)" ;;
                *)     s="ghproxy.com (URL prefix proxy)" ;;
            esac ;;
        mirror.label_mirror_ghproxy)
            case "$lang" in
                zh-CN) s="mirror.ghproxy.com" ;; zh-TW) s="mirror.ghproxy.com" ;;
                ja)    s="mirror.ghproxy.com" ;;
                ko)    s="mirror.ghproxy.com" ;;
                *)     s="mirror.ghproxy.com" ;;
            esac ;;
        mirror.label_kgithub)
            case "$lang" in
                zh-CN) s="kgithub.com (域名替换)" ;; zh-TW) s="kgithub.com (域名替換)" ;;
                ja)    s="kgithub.com (ドメイン置換)" ;;
                ko)    s="kgithub.com (도메인 교체)" ;;
                *)     s="kgithub.com (domain swap)" ;;
            esac ;;
        mirror.label_gitclone)
            case "$lang" in
                zh-CN) s="gitclone.com (仅 Git Clone 加速)" ;; zh-TW) s="gitclone.com (僅 Git Clone 加速)" ;;
                ja)    s="gitclone.com (Git Clone のみアクセラレーション)" ;;
                ko)    s="gitclone.com (Git Clone 전용 가속)" ;;
                *)     s="gitclone.com (Git Clone acceleration only)" ;;
            esac ;;
        mirror.unavailable)
            case "$lang" in
                zh-CN) s="不可用 (HTTP %s)" ;; zh-TW) s="不可用 (HTTP %s)" ;;
                ja)    s="利用不可 (HTTP %s)" ;;
                ko)    s="사용 불가 (HTTP %s)" ;;
                *)     s="unavailable (HTTP %s)" ;;
            esac ;;
        mirror.custom_prompt)
            case "$lang" in
                zh-CN) s="请输入镜像前缀 URL（如 https://ghproxy.net/）或域名替换主机（如 kgithub.com）: " ;;
                zh-TW) s="請輸入鏡像前綴 URL（如 https://ghproxy.net/）或域名替換主機（如 kgithub.com）: " ;;
                ja)    s="ミラープレフィックスURL（例: https://ghproxy.net/）またはドメイン置換ホスト（例: kgithub.com）を入力: " ;;
                ko)    s="미러 접두사 URL(예: https://ghproxy.net/) 또는 도메인 교체 호스트(예: kgithub.com) 입력: " ;;
                *)     s="Enter mirror prefix URL (e.g. https://ghproxy.net/) or domain swap host (e.g. kgithub.com): " ;;
            esac ;;
        mirror.custom_chosen)
            case "$lang" in
                zh-CN) s="使用自定义镜像：%s [%s]" ;; zh-TW) s="使用自訂鏡像：%s [%s]" ;;
                ja)    s="カスタムミラー使用: %s [%s]" ;;
                ko)    s="사용자 지정 미러 사용: %s [%s]" ;;
                *)     s="Using custom mirror: %s [%s]" ;;
            esac ;;
        mirror.invalid_number)
            case "$lang" in
                zh-CN) s="无效序号，请重新输入 [默认=%s]: " ;; zh-TW) s="無效序號，請重新輸入 [預設=%s]: " ;;
                ja)    s="無効な番号です。再入力してください [既定=%s]: " ;;
                ko)    s="잘못된 번호입니다. 다시 입력하세요 (기본값=%s): " ;;
                *)     s="Invalid number, enter again [default=%s]: " ;;
            esac ;;
        mirror.invalid_input)
            case "$lang" in
                zh-CN) s="无效输入，请输入序号 [默认=%s]: " ;; zh-TW) s="無效輸入，請輸入序號 [預設=%s]: " ;;
                ja)    s="無効な入力です。番号を入力してください [既定=%s]: " ;;
                ko)    s="잘못된 입력입니다. 번호를 입력하세요 (기본값=%s): " ;;
                *)     s="Invalid input, enter a number [default=%s]: " ;;
            esac ;;
        mirror.recommended)
            case "$lang" in
                zh-CN) s="推荐" ;; zh-TW) s="推薦" ;;
                ja)    s="推奨" ;;
                ko)    s="추천" ;;
                *)     s="(recommended)" ;;
            esac ;;
        lang.option_en)
            case "$lang" in
                zh-CN) s="English" ;; zh-TW) s="English" ;;
                ja)    s="English" ;;
                ko)    s="English" ;;
                *)     s="English" ;;
            esac ;;
        lang.option_zh_cn)
            case "$lang" in
                zh-CN) s="简体中文" ;; zh-TW) s="簡體中文" ;;
                ja)    s="簡體中国語" ;;
                ko)    s="간체 중국어" ;;
                *)     s="Simplified Chinese" ;;
            esac ;;
        lang.option_zh_tw)
            case "$lang" in
                zh-CN) s="繁體中文" ;; zh-TW) s="繁體中文" ;;
                ja)    s="正體中国語" ;;
                ko)    s="정체 중국어" ;;
                *)     s="Traditional Chinese" ;;
            esac ;;
        lang.option_ja)
            case "$lang" in
                zh-CN) s="日本語" ;; zh-TW) s="日本語" ;;
                ja)    s="日本語" ;;
                ko)    s="일본어" ;;
                *)     s="Japanese" ;;
            esac ;;
        lang.option_ko)
            case "$lang" in
                zh-CN) s="한국어" ;; zh-TW) s="한국어" ;;
                ja)    s="韓国語" ;;
                ko)    s="한국어" ;;
                *)     s="Korean" ;;
            esac ;;
        dl.mirror_failed)
            case "$lang" in
                zh-CN) s="镜像加速下载失败（exit %s），回退直连重试 ..." ;; zh-TW) s="鏡像加速下載失敗（exit %s），回退直連重試 ..." ;;
                ja)    s="ミラー加速ダウンロード失敗（exit %s）、ダイレクト再接続を試行中..." ;;
                ko)    s="미러 가속 다운로드 실패(exit %s), 직련 재시도 중..." ;;
                *)     s="Mirror-accelerated download failed (exit %s), falling back to direct retry..." ;;
            esac ;;
        dl.direct_retry_success)
            case "$lang" in
                zh-CN) s="直连重试成功" ;; zh-TW) s="直連重試成功" ;;
                ja)    s="ダイレクト再接続成功" ;;
                ko)    s="직련 재시도 성공" ;;
                *)     s="Direct retry succeeded" ;;
            esac ;;
        dl.clone_failed)
            case "$lang" in
                zh-CN) s="镜像 clone 失败，回退直连：%s" ;; zh-TW) s="鏡像 clone 失敗，回退直連：%s" ;;
                ja)    s="ミラークローン失敗、ダイレクトフォールバック: %s" ;;
                ko)    s="미러 clone 실패, 직련 폴백: %s" ;;
                *)     s="Mirror clone failed, falling back to direct: %s" ;;
            esac ;;
        combo.unknown_smart_install)
            case "$lang" in
                zh-CN) s="未知的 SMART_INSTALL_COMBO='${SMART_INSTALL_COMBO}'，忽略并回退到交互选择。" ;; zh-TW) s="未知的 SMART_INSTALL_COMBO='${SMART_INSTALL_COMBO}'，忽略並回退到交互選擇。" ;;
                ja)    s="不明な SMART_INSTALL_COMBO='${SMART_INSTALL_COMBO}'、無視して対話選択にフォールバックします。" ;;
                ko)    s="알 수 없는 SMART_INSTALL_COMBO='${SMART_INSTALL_COMBO}' 무시하고 상호작용 선택으로 폴백." ;;
                *)     s="Unknown SMART_INSTALL_COMBO='${SMART_INSTALL_COMBO}', ignoring and falling back to interactive selection." ;;
            esac ;;
        combo.headless_recommended)
            case "$lang" in
                zh-CN) s="(无头模式) 推荐配置：Zinit + Starship。" ;; zh-TW) s="(無頭模式) 推荐配置：Zinit + Starship。" ;;
                ja)    s="(ヘッドレス) 推奨構成: Zinit + Starship。" ;;
                ko)    s="(헤드리스) 추천 구성: Zinit + Starship." ;;
                *)     s="(headless) Recommended config: Zinit + Starship." ;;
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
        prompt.zshrc_overwrite)
            case "$lang" in
                zh-CN) s="用推荐模板完整覆盖 ~/.zshrc（会合并原有配置，备份到 .bak.*）？" ;;
                zh-TW) s="用推薦模板完整覆蓋 ~/.zshrc（會合併原有配置，備份到 .bak.*）？" ;;
                ja)    s="推奨テンプレートで ~/.zshrc を完全に上書きしますか（既存設定は .bak.* にバックアップ）？" ;;
                ko)    s="권장 템플릿으로 ~/.zshrc를 완전히 덮어쓰시겠습니까 (기존 설정은 .bak.* 백업)? (권장)" ;;
                *)     s="Overwrite ~/.zshrc with recommended template? (recommended, merges your existing config)" ;;
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
        combo.title)
            case "$lang" in
                zh-CN) s="选择配置组合（推荐 Zinit + Starship，也可选用 Oh My Zsh / Powerlevel10k 备选）：" ;;
                zh-TW) s="選擇配置組合（推薦 Zinit + Starship，也可選用 Oh My Zsh / Powerlevel10k 備選）：" ;;
                ja)    s="構成を選択してください（推奨: Zinit + Starship、代替案として Oh My Zsh / Powerlevel10k も利用可能）：" ;;
                ko)    s="구성 선택 (추천: Zinit + Starship, Oh My Zsh / Powerlevel10k도 가능):" ;;
                *)     s="Select configuration combo (recommended: Zinit + Starship, also available: Oh My Zsh / Powerlevel10k as alternatives):" ;;
            esac ;;
        combo.option1.new)
            case "$lang" in
                zh-CN) s="  1) (推荐) Zinit + Starship —— 全新安装，轻量现代" ;;
                zh-TW) s="  1) (推薦) Zinit + Starship —— 全新安裝，輕量現代" ;;
                ja)    s="  1) (推奨) Zinit + Starship —— 新規インストール、軽量モダン" ;;
                ko)    s="  1) (추천) Zinit + Starship —— 신규 설치, 경량 현대적" ;;
                *)     s="  1) (recommended) Zinit + Starship —— fresh install, lightweight modern" ;;
            esac ;;
        combo.option2.new)
            case "$lang" in
                zh-CN) s="  2) Oh My Zsh + Powerlevel10k —— 经典方案（将为你安装 OMZ 与 p10k）" ;;
                zh-TW) s="  2) Oh My Zsh + Powerlevel10k —— 經典方案（將為你安裝 OMZ 與 p10k）" ;;
                ja)    s="  2) Oh My Zsh + Powerlevel10k —— クラシックソリューション（OMZ と p10k をインストールします）" ;;
                ko)    s="  2) Oh My Zsh + Powerlevel10k —— 클래식 솔루션 (OMZ 및 p10k를 설치합니다)" ;;
                *)     s="  2) Oh My Zsh + Powerlevel10k —— classic solution (will install OMZ & p10k)" ;;
            esac ;;
        combo.option3.new)
            case "$lang" in
                zh-CN) s="  3) Zinit + Powerlevel10k —— Zinit 管理 p10k 主题" ;;
                zh-TW) s="  3) Zinit + Powerlevel10k —— Zinit 管理 p10k 主題" ;;
                ja)    s="  3) Zinit + Powerlevel10k —— Zinit가 관리하는 p10k 테마" ;;
                ko)    s="  3) Zinit + Powerlevel10k —— Zinit가 관리하는 p10k 테마" ;;
                *)     s="  3) Zinit + Powerlevel10k — Zinit manages p10k theme" ;;
            esac ;;
        combo.option1.keep)
            case "$lang" in
                zh-CN) s="  1) (推荐) 移除 OMZ/p10k，全新 Zinit + Starship" ;;
                zh-TW) s="  1) (推薦) 移除 OMZ/p10k，全新 Zinit + Starship" ;;
                ja)    s="  1) (推奨) OMZ/p10kを削除し、全新のZinit + Starship" ;;
                ko)    s="  1) (추천) OMZ/p10k 제거 및全新 Zinit + Starship" ;;
                *)     s="  1) (recommended) Remove OMZ/p10k, fresh Zinit + Starship" ;;
            esac ;;
        combo.option2.keep)
            case "$lang" in
                zh-CN) s="  2) 保留 OMZ + p10k，配合使用" ;;
                zh-TW) s="  2) 保留 OMZ + p10k，配合使用" ;;
                ja)    s="  2) OMZ + p10kを保持し、併用する" ;;
                ko)    s="  2) OMZ + p10k 유지 및 함께 사용" ;;
                *)     s="  2) Keep OMZ + p10k, use together" ;;
            esac ;;
        combo.option3.keep)
            case "$lang" in
                zh-CN) s="  3) 移除 OMZ，保留 p10k（Zinit + Powerlevel10k）" ;;
                zh-TW) s="  3) 移除 OMZ，保留 p10k（Zinit + Powerlevel10k）" ;;
                ja)    s="  3) OMZ를 삭제하고, p10k를 유지（Zinit + Powerlevel10k）" ;;
                ko)    s="  3) OMZ 제거, p10k 유지（Zinit + Powerlevel10k）" ;;
                *)     s="  3) Remove OMZ, keep p10k (Zinit + Powerlevel10k)" ;;
            esac ;;
        combo.detected)
            case "$lang" in
                zh-CN) s="已检测到已安装:%s。" ;;
                zh-TW) s="已檢測到已安裝:%s。" ;;
                ja)    s="検出済み:%s。" ;;
                ko)    s="감지됨:%s。" ;;
                *)     s="Detected installed:%s." ;;
            esac ;;
        combo.zinit_starship)
            case "$lang" in
                zh-CN) s="已选择（推荐）：Zinit + Starship。正在清除 OMZ/p10k 残留…" ;;
                zh-TW) s="已選擇（推薦）：Zinit + Starship。正在清除 OMZ/p10k 殘留…" ;;
                ja)    s="選択済み（推奨）：Zinit + Starship。OMZ/p10k 残存をクリア中…" ;;
                ko)    s="선택됨 (추천): Zinit + Starship. OMZ/p10k 잔여물 정리 중…" ;;
                *)     s="Selected (recommended): Zinit + Starship. Clearing OMZ/p10k remnants…" ;;
            esac ;;
        combo.keep_omz)
            case "$lang" in
                zh-CN) s="已选择：Oh My Zsh + Powerlevel10k（经典方案）。" ;;
                zh-TW) s="已選擇：Oh My Zsh + Powerlevel10k（經典方案）。" ;;
                ja)    s="選択済み：Oh My Zsh + Powerlevel10k（クラシック構成）。" ;;
                ko)    s="선택됨: Oh My Zsh + Powerlevel10k (클래식 솔루션)." ;;
                *)     s="Selected: Oh My Zsh + Powerlevel10k (classic)." ;;
            esac ;;
        combo.zinit_p10k)
            case "$lang" in
                zh-CN) s="已选择：Zinit + Powerlevel10k。正在清除 OMZ 残留…" ;;
                zh-TW) s="已選擇：Zinit + Powerlevel10k。正在清除 OMZ 殘留…" ;;
                ja)    s="選択済み：Zinit + Powerlevel10k。OMZ 残存をクリア中…" ;;
                ko)    s="선택됨: Zinit + Powerlevel10k. OMZ 잔여물 정리 중…" ;;
                *)     s="Selected: Zinit + Powerlevel10k. Clearing OMZ remnants…" ;;
            esac ;;
        combo.prompt)
            case "$lang" in
                zh-CN) s="输入序号 [默认=1]: " ;;
                zh-TW) s="輸入序號 [預設=1]: " ;;
                ja)    s="番号を入力 [既定=1]: " ;;
                ko)    s="번호 입력 [기본=1]: " ;;
                *)     s="Enter number [default=1]: " ;;
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
    printf "  %d) %s (default)\n" 1 "$(msg lang.option_en)"
    printf "  %d) %s\n" 2 "$(msg lang.option_zh_cn)"
    printf "  %d) %s\n" 3 "$(msg lang.option_zh_tw)"
    printf "  %d) %s\n" 4 "$(msg lang.option_ja)"
    printf "  %d) %s\n" 5 "$(msg lang.option_ko)"
    echo -n "$(msg lang.prompt)"
    read -r REPLY || REPLY=""
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

# 候选镜像：id | label | prefix | type
#   direct = 直连（prefix 为空）
#   prefix = URL 前缀代理，可加速 raw 文件与 releases 二进制下载（ghproxy 系列）
#   domain = 域名替换型，仅替换 github.com 主机；raw.githubusercontent.com 不支持，保持直连
#   clone  = 仅加速 git clone 的仓库地址；绝不改写 releases / archive / raw 等文件下载
#            否则会把二进制下载地址拼成 404 —— 这正是 starship/atuin 安装报
#            "curl exit code 22" 的根因（gitclone.com 不是前缀代理）
MIRROR_IDS=(); MIRROR_PREFIXES=(); MIRROR_TYPES=()
_add_mirror() { MIRROR_IDS+=("$1"); MIRROR_PREFIXES+=("$3"); MIRROR_TYPES+=("${4:-prefix}"); }
_add_mirror "direct"             ""                            ""                            "direct"
_add_mirror "ghproxy.net"        ""                            "https://ghproxy.net/"        "prefix"
_add_mirror "ghproxy.com"        ""                            "https://ghproxy.com/"        "prefix"
_add_mirror "mirror.ghproxy.com" ""                            "https://mirror.ghproxy.com/" "prefix"
_add_mirror "kgithub.com"        ""                            "kgithub.com"                 "domain"
_add_mirror "gitclone.com"       ""                            "https://gitclone.com/"       "clone"

# Localized mirror label for index $1
_mirror_label() {
    case "$1" in
        0) msg mirror.label_direct ;;
        1) msg mirror.label_ghproxy_net ;;
        2) msg mirror.label_ghproxy_com ;;
        3) msg mirror.label_mirror_ghproxy ;;
        4) msg mirror.label_kgithub ;;
        5) msg mirror.label_gitclone ;;
        *) msg mirror.label_direct ;;
    esac
}

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
    for (( i=0; i<${#MIRROR_IDS[@]}; i++ )); do
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
            info "  $(_mirror_label $i) -> ${t}s"
        else
            MIRROR_TIMES[$i]="999"
            warn "  $(_mirror_label $i) -> $(msg mirror.unavailable \"${code:-000}\")"
        fi
    done
    rm -f "$body"
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
            direct|none|'') GH_MIRROR=""; GH_MIRROR_TYPE="direct" ;;
            *)
                GH_MIRROR="${SMART_INSTALL_GH_MIRROR}"
                GH_MIRROR_TYPE="$(_guess_mirror_type "$GH_MIRROR")"
                ;;
        esac
        info "GitHub 加速镜像（来自 SMART_INSTALL_GH_MIRROR）：${GH_MIRROR:-直连} [${GH_MIRROR_TYPE}]"
        return 0
    fi
    # SKIP_DEPS 时不下载外部包，跳过测速，直接用直连。
    if [[ "${SKIP_DEPS:-0}" == "1" ]]; then
        GH_MIRROR=""; GH_MIRROR_TYPE="direct"; info "SKIP_DEPS=1：跳过镜像测速，使用直连。"; return 0
    fi

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
            info "$(msg mirror.auto_selected "$(_mirror_label $best)" "${MIRROR_TIMES[$best]}" "${GH_MIRROR_TYPE}")"
        else
            GH_MIRROR=""; GH_MIRROR_TYPE="direct"; warn "$(msg mirror.all_unavailable)"
        fi
        return 0
    fi

    echo
    info "$(msg mirror.select)"
    local n=${#MIRROR_IDS[@]} i d=1
    local fastest_idx=""
    for i in $(mirror_ordered_indices); do
        [[ "${MIRROR_TIMES[$i]}" != "999" ]] && { fastest_idx="$i"; break; }
    done
    [[ -z "$fastest_idx" ]] && fastest_idx=0   # 全部不可用时默认直连
    for (( i=0; i<n; i++ )); do
        local mark=""
        [[ "$i" == "$fastest_idx" ]] && mark=" $(msg mirror.recommended)"
        printf "  %2d) %s%s  [%ss]\n" "$d" "$(_mirror_label $i)" "$mark" "${MIRROR_TIMES[$i]}"
        d=$((d+1))
    done
    printf "  %2d) %s\n" "$d" "$(msg mirror.manual)"
    local custom_d=$d
    local choice="" REPLY="" default_d=$((fastest_idx+1))
    echo -n "$(msg mirror.prompt "$default_d")"
    while true; do
        read -r REPLY
        if [[ -z "$REPLY" ]]; then
            choice=$fastest_idx; break
        elif [[ "$REPLY" =~ ^[0-9]+$ ]]; then
            if (( REPLY >= 1 && REPLY <= n )); then
                choice=$((REPLY-1)); break
            elif (( REPLY == custom_d )); then
                echo -n "  $(msg mirror.custom_prompt)"; read -r GH_MIRROR
                GH_MIRROR_TYPE="$(_guess_mirror_type "$GH_MIRROR")"
                if [[ "$GH_MIRROR_TYPE" == "prefix" && "$GH_MIRROR" != */ ]]; then
                    GH_MIRROR="${GH_MIRROR}/"
                fi
                info "$(msg mirror.custom_chosen "$GH_MIRROR" "${GH_MIRROR_TYPE}")"
                return 0
            else
                echo -n "  $(msg mirror.invalid_number "$default_d")"; continue
            fi
        else
            echo -n "  $(msg mirror.invalid_input "$default_d")"; continue
        fi
    done
    GH_MIRROR="${MIRROR_PREFIXES[$choice]}"
    GH_MIRROR_TYPE="${MIRROR_TYPES[$choice]}"
    info "$(msg mirror.chosen "${_mirror_label $choice}" "${MIRROR_TIMES[$choice]}" "$GH_MIRROR_TYPE")"
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
# 若镜像加速失败，自动回退直连重试一次——避免镜像地址形态不支持时直接判死。
run_with_mirror_dl() {
    local cmd="$1"
    if [[ -z "$GH_MIRROR" || "${GH_MIRROR_TYPE:-direct}" == "direct" ]]; then
        eval "$cmd"
        return $?
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
        warn "$(msg dl.mirror_failed "$rc")"
        # 必须先归零：成功时 `||` 会短路，否则会沿用镜像失败时的 rc
        rc=0
        eval "$cmd" || rc=$?
        if (( rc == 0 )); then
            success "$(msg dl.direct_retry_success)"
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
        warn "$(msg dl.clone_failed "$src")"
        rm -rf "$dest" 2>/dev/null || true
        git clone --depth 1 "$src" "$dest" 2>/dev/null && return 0
    fi
    return 1
}

select_language

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
        SMART_INSTALL_LANG="$LANG_CODE" exec bash "$ENTWARE_INSTALLER"
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
info "$(msg os.detected "$OS_TYPE")"

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
info "$(msg phase1)"

check_zsh

if [[ "${SKIP_DEPS:-0}" != "1" ]]; then
    if command -v fzf >/dev/null 2>&1; then
        success "fzf is already installed"
    elif install_pkg_soft "fzf" "fzf" "fzf"; then
        success "fzf installed (package manager)"
    else
        warn "fzf 包管理器安装失败，尝试官方 git clone 安装（走镜像加速）..."
        fzf_dir="${XDG_DATA_HOME:-$HOME/.local/share}/fzf"
        if git_clone_repo "https://github.com/junegunn/fzf.git" "$fzf_dir" \
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
info "$(msg phase2)"
if command -v starship >/dev/null 2>&1; then
    success "Starship is installed: $(starship --version 2>/dev/null || echo present)"
    if prompt_yes "$(msg prompt.starship_upgrade)" 0; then
        run_with_mirror_dl 'curl -fsSL https://starship.rs/install.sh | sh -s -- -y' \
            || warn "Starship upgrade failed (non-fatal)"
    fi
elif [[ "${SKIP_DEPS:-0}" != "1" ]] && prompt_yes "$(msg prompt.starship)" 1; then
    run_with_mirror_dl 'curl -fsSL https://starship.rs/install.sh | sh -s -- -y' \
        || error "Starship install failed. Retry with SKIP_DEPS=1 to skip external downloads."
    success "Starship installed"
fi

# ------------------------------------------------------------------
# Phase 2b/4: Optional Atuin (shell-history sync/search)
# ------------------------------------------------------------------
info "$(msg phase2b)"
if command -v atuin >/dev/null 2>&1; then
    success "Atuin is installed: $(atuin --version 2>/dev/null || echo present)"
elif [[ "${SKIP_DEPS:-0}" != "1" ]] && prompt_yes "$(msg prompt.atuin)" 0; then
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
info "$(msg phase3)"
ZINIT_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/zinit.git"

if [[ -d "$ZINIT_HOME" ]]; then
    success "Zinit is installed at $ZINIT_HOME"
    if prompt_yes "$(msg prompt.zinit_pull)" 0; then
        ( cd "$ZINIT_HOME" && git pull --ff-only 2>/dev/null ) || warn "git pull failed (non-fatal)"
    fi
elif [[ "${SKIP_DEPS:-0}" != "1" ]] && prompt_yes "$(msg prompt.zinit)" 1; then
    mkdir -p "$(dirname "$ZINIT_HOME")"
    git_clone_repo "https://github.com/zdharma-continuum/zinit.git" "$ZINIT_HOME" \
        || error "Zinit clone failed. Check your internet connection."
    success "Zinit installed"
fi

# If the user didn't install Zinit, fall back: clone zsh-smart-complete directly
# so we can still provide a working `source ~/.../zsh-smart-complete.plugin.zsh`.
SMART_COMPLETE_INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/plugins/imonior---zsh-smart-complete"
if [[ ! -d "$SMART_COMPLETE_INSTALL_DIR" && "${SKIP_DEPS:-0}" != "1" ]]; then
    info "Cloning zsh-smart-complete plugin repo ..."
    mkdir -p "$(dirname "$SMART_COMPLETE_INSTALL_DIR")"
    git_clone_repo "https://github.com/imonior/zsh-smart-complete.git" "$SMART_COMPLETE_INSTALL_DIR" \
        || warn "zsh-smart-complete clone failed. If running Zinit, zinit light will clone it automatically."
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
    if prompt_yes "$(msg prompt.remove_plugin "$plugin_name")" 1; then
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
    if ! prompt_yes "$(msg prompt.omz)" 1; then
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
        if git_clone_repo "https://github.com/romkatzen/powerlevel10k.git" "$p10k_dir"; then
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

_remove_omz() {
    # 交互确认：用户选Yes才删除，默认No避免误操作
    comment_out_zshrc 'oh-my-zsh'
    if [[ -d "$HOME/.oh-my-zsh" ]] && prompt_yes "Delete ~/.oh-my-zsh directory (backed up as .bak)?" 1; then
        mv "$HOME/.oh-my-zsh" "$HOME/.oh-my-zsh.bak.$(date +%s)" && success "Backed up + removed ~/.oh-my-zsh"
    fi
}
_remove_p10k() {
    # 交互确认：用户选Yes才删除，默认No避免误操作
    comment_out_zshrc 'powerlevel10k'
    comment_out_zshrc 'p10k.zsh'
    if [[ -f "$HOME/.p10k.zsh" ]] && prompt_yes "Delete ~/.p10k.zsh (backed up)?" 1; then
        mv "$HOME/.p10k.zsh" "$HOME/.p10k.zsh.bak.$(date +%s)" && success "Backed up + removed ~/.p10k.zsh"
    fi
    if [[ -d "$HOME/.powerlevel10k" ]] && prompt_yes "Delete ~/.powerlevel10k directory (backed up)?" 1; then
        mv "$HOME/.powerlevel10k" "$HOME/.powerlevel10k.bak.$(date +%s)" && success "Removed ~/.powerlevel10k"
    fi
}
_apply_combo() {
    CONFIG_COMBO="$1"
    case "$CONFIG_COMBO" in
        keep-omz)
            info "$(msg combo.keep_omz)"
            _ensure_omz
            _ensure_p10k_omz ;;
        zinit-p10k)
            info "$(msg combo.zinit_p10k)"
            _remove_omz
            _ensure_p10k_zinit ;;
        zinit-starship)
            info "$(msg combo.zinit_starship)"
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
            *) warn "$(msg combo.unknown_smart_install)" ;;
        esac
    fi
    if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
        _apply_combo "zinit-starship"
        info "$(msg combo.headless_recommended)"
        return 0
    fi

    # 无论是否已安装 OMZ/p10k，都给出组合选择；全部未安装时推荐 Zinit+Starship，
    # 同时分别提供 Oh My Zsh / Powerlevel10k 备选。
    echo
    info "$(msg combo.title)"
    if (( HAS_OMZ == 0 && HAS_P10K == 0 )); then
        echo "$(msg combo.option1.new)"
        echo "$(msg combo.option2.new)"
        echo "$(msg combo.option3.new)"
    else
        local detected_msg=""
        (( HAS_OMZ )) && detected_msg+=" Oh My Zsh" || true
        (( HAS_P10K )) && detected_msg+=" Powerlevel10k" || true
        info "$(msg combo.detected "${detected_msg}")"
        echo "$(msg combo.option1.keep)"
        echo "$(msg combo.option2.keep)"
        echo "$(msg combo.option3.keep)"
    fi
    echo -n "$(msg combo.prompt)"
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
info "$(msg phase4)"

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
    if prompt_yes "Overwrite with recommended template?" 1; then
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
    resolved_zshrc="$(resolve_template "zshrc.example" "$ZSHRC_FILE")"
    apply_template "$resolved_zshrc" "$ZSHRC_FILE"
    success ".zshrc created with zsh-smart-complete integration"
else
    if grep -q "zsh-smart-complete" "$ZSHRC_FILE"; then
        # Already has integration block — offer to replace with fresh template
        info ".zshrc already has zsh-smart-complete block"
        if prompt_yes "$(msg prompt.zshrc_overwrite)" 1; then
            cp -f "$ZSHRC_FILE" "${ZSHRC_FILE}.bak.$(date +%s)"
            resolved_zshrc="$(resolve_template "zshrc.example" "$ZSHRC_FILE")"
            apply_template "$resolved_zshrc" "$ZSHRC_FILE"
            success ".zshrc replaced with recommended template (backup kept at .bak.*)"
        else
            # Ask if they still want to append the integration block in case it's stale
            if prompt_yes "Re-append zsh-smart-complete integration block?" 0; then
                cp -f "$ZSHRC_FILE" "${ZSHRC_FILE}.bak.$(date +%s)"
                printf '\n%s\n' "$(build_zsc_integration)" >> "$ZSHRC_FILE"
                success ".zshrc updated with integration block (backup kept at .bak.*)"
            fi
        fi
    else
        # No integration block yet — offer overwrite or append
        if prompt_yes "$(msg prompt.zshrc_overwrite)" 1; then
            cp -f "$ZSHRC_FILE" "${ZSHRC_FILE}.bak.$(date +%s)"
            resolved_zshrc="$(resolve_template "zshrc.example" "$ZSHRC_FILE")"
            apply_template "$resolved_zshrc" "$ZSHRC_FILE"
            success ".zshrc replaced with recommended template (backup kept at .bak.*)"
        elif prompt_yes "$(msg prompt.zshrc_append)" 1; then
            cp -f "$ZSHRC_FILE" "${ZSHRC_FILE}.bak.$(date +%s)"
            printf '\n%s\n' "$(build_zsc_integration)" >> "$ZSHRC_FILE"
            success ".zshrc updated with integration block (backup kept at .bak.*)"
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
