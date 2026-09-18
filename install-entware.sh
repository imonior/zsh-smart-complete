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
    read -r -n 1 REPLY || REPLY=""; echo
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
                zh-CN) s="仅历史记录（推荐）" ;; zh-TW) s="僅歷史記錄（推薦）" ;;
                ja)    s="履歴のみ（推奨）" ;;  ko)    s="기록만 (권장)" ;;
                *)     s="history only (recommended)" ;;
            esac ;;
        opt.strategy_completion)
            case "$lang" in
                zh-CN) s="仅补全系统" ;; zh-TW) s="僅補全系統" ;;
                ja)    s="補完のみ" ;;     ko)    s="완성만" ;;
                *)     s="completion only" ;;
            esac ;;
        opt.strategy_both)
            case "$lang" in
                zh-CN) s="先历史、后补全" ;; zh-TW) s="先歷史、後補全" ;;
                ja)    s="履歴のち補完" ;;   ko)    s="기록 후 완성" ;;
                *)     s="history, then completion" ;;
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
# Script identity / helpers
# ------------------------------------------------------------------
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"

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
_add_mirror() { MIRROR_IDS+=("$1"); MIRROR_LABELS+=("$2"); MIRROR_PREFIXES+=("$3"); MIRROR_TYPES+=("${4:-prefix}"); }
_add_mirror "direct"             "直连（不使用加速）"              ""                            "direct"
_add_mirror "ghproxy.net"        "ghproxy.net (URL 前缀代理)"      "https://ghproxy.net/"        "prefix"
_add_mirror "ghproxy.com"        "ghproxy.com (URL 前缀代理)"      "https://ghproxy.com/"        "prefix"
_add_mirror "mirror.ghproxy.com" "mirror.ghproxy.com"              "https://mirror.ghproxy.com/" "prefix"
_add_mirror "kgithub.com"        "kgithub.com (域名替换)"          "kgithub.com"                 "domain"
_add_mirror "gitclone.com"       "gitclone.com (仅 Git Clone 加速)" "https://gitclone.com/"       "clone"

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
            info "  ${MIRROR_LABELS[$i]} -> ${t}s"
        else
            MIRROR_TIMES[$i]="999"
            warn "  ${MIRROR_LABELS[$i]} -> 不可用 (HTTP ${code:-000})"
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
            info "已自动选择最快镜像：${MIRROR_LABELS[$best]} (${MIRROR_TIMES[$best]}s) [${GH_MIRROR_TYPE}]"
        else
            GH_MIRROR=""; GH_MIRROR_TYPE="direct"; warn "所有镜像均不可用，回退到直连。"
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
        [[ "$i" == "$fastest_idx" ]] && mark=" (推荐)"
        printf "  %2d) %s%s  [%ss]\n" "$d" "${MIRROR_LABELS[$i]}" "$mark" "${MIRROR_TIMES[$i]}"
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
                echo -n "  请输入镜像前缀 URL（如 https://ghproxy.net/ ）或域名替换主机（如 kgithub.com）: "
                read -r GH_MIRROR
                GH_MIRROR_TYPE="$(_guess_mirror_type "$GH_MIRROR")"
                if [[ "$GH_MIRROR_TYPE" == "prefix" && "$GH_MIRROR" != */ ]]; then
                    GH_MIRROR="${GH_MIRROR}/"
                fi
                info "使用自定义镜像：$GH_MIRROR [${GH_MIRROR_TYPE}]"
                return 0
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
        warn "镜像加速下载失败（exit $rc），回退直连重试 ..."
        # 必须先归零：成功时 `||` 会短路，否则会沿用镜像失败时的 rc
        rc=0
        eval "$cmd" || rc=$?
        if (( rc == 0 )); then
            success "直连重试成功"
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
        warn "镜像 clone 失败，回退直连：$src"
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
[[ -n "$OPKG" ]] || error "opkg not found. This installer targets Entware environments.
Install Entware first (QNAP: enable it in App Center / via the Entware QPKG;
generic: https://github.com/Entware/Entware)."

info "Detected Entware — opkg at: $OPKG"
info "Home directory: $HOME"

# Select a GitHub acceleration mirror up front so every clone / raw download
# below can use it. Honors SMART_INSTALL_GH_MIRROR and NONINTERACTIVE.
select_mirror

if [[ "$(id -u)" != "0" ]]; then
    warn "You are not root (uid=$(id -u)). On QNAP the admin user is normally root; continuing without sudo."
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
        success "Zsh is installed: $(zsh --version 2>/dev/null | head -n 1) -> $ZSH_BIN"
        return 0
    fi
    warn "未检测到 Zsh —— 本插件依赖 Zsh，将通过 opkg 安装。"
    if [[ -z "$OPKG" ]]; then
        error "未找到 opkg，无法自动安装 Zsh。请先配置 Entware/opkg 后重试。"
    fi
    info "Installing zsh via opkg ..."
    "$OPKG" install zsh || error "opkg install zsh 失败，请检查 Entware feed / 网络连接。"
    ZSH_BIN="$(command -v zsh)"
    [[ -n "$ZSH_BIN" ]] || ZSH_BIN="/opt/bin/zsh"
    success "Zsh installed at $ZSH_BIN"
    info "安装完成后，请重新登录或执行： exec $ZSH_BIN"
    return 0
}
check_zsh

# Set the login shell. Entware has no /etc/shells + chsh.
info "Switching your login shell to zsh ..."
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
    success "Added 'exec $ZSH_BIN' to $PROFILE_FILE"
    warn "Or set the login shell via QNAP GUI: Control Panel -> Terminal -> Default shell -> zsh"
else
    info "$PROFILE_FILE already launches zsh (skipping)"
fi

# Optional fzf (the plugin core works without it). Try opkg, then fall back to
# the official git-clone install (mirror-accelerated).
if [[ "${SKIP_DEPS:-0}" != "1" ]] && prompt_yes "Install fzf (optional, nicer history UI)?" 0; then
    if command -v fzf >/dev/null 2>&1; then
        success "fzf is already installed"
    elif "$OPKG" install fzf 2>/dev/null; then
        success "fzf installed (opkg)"
    else
        warn "fzf 不在 entware feed，尝试官方 git clone 安装（走镜像加速）..."
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
# 3. Optional Starship prompt
# ------------------------------------------------------------------
info "$(msg phase2)"
if command -v starship >/dev/null 2>&1; then
    success "Starship present: $(starship --version 2>/dev/null || echo present)"
elif [[ "${SKIP_DEPS:-0}" != "1" ]] && prompt_yes "$(msg prompt.starship)" 0; then
    info "Trying opkg install starship ..."
    if "$OPKG" install starship 2>/dev/null; then
        success "Starship installed"
        STARSHIP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
        STARSHIP_CONFIG_FILE="${STARSHIP_CONFIG_DIR}/starship.toml"
        mkdir -p "$STARSHIP_CONFIG_DIR"
        if [[ ! -f "$STARSHIP_CONFIG_FILE" ]]; then
            cat > "$STARSHIP_CONFIG_FILE" <<'TOML'
add_newline = false
# Two-line: USER (icon) + current dir on line 1; ":>" on line 2
format = """
[$user] › $directory
$character"""
[username]
show_always = true
style_user = "bold green"
style_root = "bold red"
format = "[ $user]($style)"
[hostname]
disabled = true
[directory]
truncation_length = 3
truncation_symbol = "…/"
style = "bold cyan"
format = "[$path]($style)"
[character]
success_symbol = "[:> ](bold green)"
error_symbol   = "[:> ](bold red)"
TOML
            success "Starship config written to $STARSHIP_CONFIG_FILE"
        fi
    else
        info "opkg 无 starship，尝试官方一键安装（走镜像加速）..."
        if run_with_mirror_dl 'curl -fsSL https://starship.rs/install.sh | sh -s -- -y' 2>/dev/null; then
            success "Starship installed (official installer, mirror-accelerated)"
        else
            warn "starship 安装失败（可稍后手动安装；插件核心不依赖 starship）。"
        fi
    fi
fi

# ------------------------------------------------------------------
# 3b. Optional Atuin (shell-history sync/search)
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
# 4. Zinit plugin manager + plugin clone
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

SMART_COMPLETE_INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/plugins/imonior---zsh-smart-complete"
if [[ ! -d "$SMART_COMPLETE_INSTALL_DIR" && "${SKIP_DEPS:-0}" != "1" ]]; then
    info "Cloning zsh-smart-complete plugin repo ..."
    mkdir -p "$(dirname "$SMART_COMPLETE_INSTALL_DIR")"
    git_clone_repo "https://github.com/imonior/zsh-smart-complete.git" "$SMART_COMPLETE_INSTALL_DIR" \
        || warn "clone failed; 'zinit light' will fetch it automatically if Zinit is installed."
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
            # Skip backups a previous run kept (e.g. zsh-autocomplete.bak.<ts>):
            # they are not active plugins, so must NOT be re-reported as conflicts.
            [[ "$(basename "$pdir")" == *.bak.* ]] && continue
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
            || warn "Update skipped for $slug (non-fatal)."
    elif [[ ! -d "$dir" ]]; then
        mkdir -p "$(dirname "$dir")"
        git_clone_repo "https://github.com/${slug}.git" "$dir" \
            || warn "Clone failed for $slug (non-fatal; Zinit will fetch it at first shell start)."
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
ZSC_OPT_STRATEGY="history"  # source of the inline grey suggestion

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
    if [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
        local REPLY=""
        echo
        echo "  $(msg opt.strategy_prompt)"
        printf "    1) %s\n" "$(msg opt.strategy_history)"
        printf "    2) %s\n" "$(msg opt.strategy_completion)"
        printf "    3) %s\n" "$(msg opt.strategy_both)"
        echo -n "  > "
        read -r REPLY || REPLY=""
        case "$REPLY" in
            2) ZSC_OPT_STRATEGY="completion" ;;
            3) ZSC_OPT_STRATEGY="history,completion" ;;
            *) ZSC_OPT_STRATEGY="history" ;;
        esac
    fi
    return 0
}

ask_smart_options

# Install the opt-in plugins only AFTER the questions, so nothing is cloned for
# a component the user declined.
ZSC_VIMODE_SNIPPET=""
if (( ZSC_OPT_VIMODE )); then
    info "Installing zsh-vi-mode (Zinit plugin) ..."
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
    info "Installing fzf-tab (Zinit plugin) ..."
    _entware_ensure_zinit_plugin "Aloxaf/fzf-tab"
    if ! command -v fzf >/dev/null 2>&1; then
        warn "fzf-tab needs the 'fzf' binary and it is not on PATH — install it (brew install fzf / apt install fzf) or fzf-tab will do nothing."
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
    info "No ~/.zshrc found — creating recommended one (with zsh-smart-complete block)..."
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
    success "Created $ZSHRC_FILE (with zsh-smart-complete integration)"
elif grep -q "zsh-smart-complete" "$ZSHRC_FILE"; then
    # The loader is already there, so we leave it alone — but still refresh OUR
    # managed options block, which is the only way to change the answers on a
    # re-run without hand-editing the file.
    cp -f "$ZSHRC_FILE" "${ZSHRC_FILE}.bak.$(date +%s)"
    _upsert_options_block "$ZSHRC_FILE" "$(build_smart_options)"
    success "$ZSHRC_FILE already references zsh-smart-complete — options block refreshed (backup kept at .bak.*)"
else
    if prompt_yes "Append zsh-smart-complete loader block to ~/.zshrc?" 1; then
        cp -f "$ZSHRC_FILE" "${ZSHRC_FILE}.bak.$(date +%s)"
        _upsert_options_block "$ZSHRC_FILE" "$(build_smart_options)"
        printf '\n%s\n' "$(build_zsc_integration)" >> "$ZSHRC_FILE"
        success "$ZSHRC_FILE updated (backup kept at .bak.*)"
    fi
fi

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
