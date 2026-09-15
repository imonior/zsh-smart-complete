# zsh-smart-complete

> 一個現代化的智慧補全與建議層，專為 Zsh 設計。
> 作為未來獨立 shell 的前端引擎。
>
> **v2.2.0** — 最新釋出：原生「打字即彈候選選單」（zsh-autocomplete 那一半）、`Alt+→` 一次接受一個詞、修復右箭頭 SS3 失效。

[English](./README.md) · [简体中文](./README.zh-CN.md) · [繁體中文](./README.zh-TW.md) · [日本語](./README.ja.md) · [한국어](./README.ko.md)

## 狀態

| 管道 | 狀態 |
| ------ | ------ |
| 建置與測試 (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| 釋出 | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| 版本 | 2.2.0 |

## 為什麼選擇我們

在同一個外掛中以簡潔的模組化架構取代 `zsh-autocomplete` 與 `zsh-autosuggestions`，並為演變成獨立 shell 而設計。

- **兩部分合為一體（v2.2.0）** — 打字時**立即彈出候選清單**（zsh-autocomplete 的行為），同時保留行內灰字建議，`→` 全量接受、`Alt+→` 一次接受一個詞（zsh-autosuggestions 的行為）。同一個外掛、同一套鍵位、兩個通道，這正是「兩個外掛互相衝突」的根本解法。
- **零外部依賴** — 核心外掛自包含；Atuin 為可選。
- **箭頭鍵全編碼綁定** — `ESC [ C` 與 `ESC O C`（應用游標鍵模式，`TERM=xterm-256color` 下終端實際傳送的形式）都綁定，不會出現「灰字在、右箭頭沒反應」。
- **與語法高亮相容** — 使用 `#zsh-smart-complete:suggestion` 標記，不覆蓋其他 highlighter。

## 架構

```
              zsh-smart-complete.plugin.zsh
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
      config            state             event/zle
         │                 │                 │
         └─────────────────┼─────────────────┘
                           │
               ┌───────────┴───────────┐
               │                       │
         engine/suggest          engine/native
               │                       │
        history/history         (使用者 compinit)
                                       │
                                   engine/menu
                              （打字即彈候選清單）
               │
      zsh fc   │   atuin (可選)   │   smart-engine (未來)
               └───────────────────┴───────────────────┘
                           │
                     display/
                 region_highlight
```

## 快速開始

### 前置條件

讓 Zsh 本身擁有 `compinit`：

```zsh
export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=1000000
export SAVEHIST=1000000
setopt appendhistory sharehistory histignorealldups

autoload -Uz compinit
compinit
```

### 安裝

> ⚠️ 此外掛同時取代 `zsh-autocomplete` 與 `zsh-autosuggestions`。

#### 方式 A — 一鍵安裝器（推薦）

```zsh
bash <(curl -fsSL https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh)
```

#### 方式 B — Zinit（手動）

```zsh
zinit light imonior/zsh-smart-complete
```

#### 方式 C — 手動克隆

```zsh
git clone https://github.com/imonior/zsh-smart-complete.git ~/.zsh-smart-complete
echo 'source ~/.zsh-smart-complete/zsh-smart-complete.plugin.zsh' >> ~/.zshrc
```

#### 國內代理加速

```zsh
SMART_INSTALL_GH_MIRROR=https://ghproxy.net/ bash -c "$(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh)"
```

## 設定

在載入外掛之前設定以下變數：

```zsh
# 主開關
: ${SMART_ENABLED:=true}
# 引擎
: ${SMART_SUGGEST:=true}
: ${SMART_COMPLETE:=true}
# 歷史後端：zsh | atuin | smart-engine（未來）
: ${SMART_HISTORY_BACKEND:=zsh}
# 介面
: ${SMART_INLINE:=true}
: ${SMART_SUGGEST_COLOR:=fg=8}

# 打字即彈候選清單（zsh-autocomplete 那一半）
: ${SMART_MENU:=true}
: ${SMART_MENU_MIN_PREFIX_CMD:=2}     # 命令列首詞至少幾個字元才列
: ${SMART_MENU_MIN_PREFIX:=1}         # 參數詞至少幾個字元才列（0 = 空格後也列）
: ${SMART_MENU_MIN_MATCHES:=2}        # 候選少於這個數就不列（單個候選由灰字承擔）
: ${SMART_MENU_MAX_PREFIX:=64}
# 節流：預設關閉。實測每次列舉只要 10~30ms，沒什麼可降的；
# 這個開關是留給「持續很貴」的補全的。開啟後，耗時 ≥ SLOW_MS 的列舉
# 會換來 COOLDOWN_KEYS 次跳過。注意：被跳過的那次按鍵不會重繪，
# 螢幕上的候選清單會消失——這正是預設設為 0 的原因。
: ${SMART_MENU_SLOW_MS:=250}
: ${SMART_MENU_COOLDOWN_KEYS:=0}

# 排查用：設成檔案路徑後，每次 tick 的決策（被閘門拒絕 / 被冷卻吞掉 /
# 命中幾個候選 / 花了多少毫秒）都會追加寫進去。「沒彈出來」到底是
# 哪種原因，螢幕上分不出來，這個日誌能。
: ${SMART_MENU_DEBUG:=}
```

## 執行時命令

```zsh
smart-status      # 印出目前狀態 + 設定
smart-disable     # 停用外掛
smart-enable      # 重新啟用
smart-reindex     # 強制重建歷史索引
smart-menu on     # 開啟打字即彈候選清單
smart-menu off    # 關閉（行內灰字建議不受影響）
smart-menu status # 檢視選單設定與上次列舉結果
```

## 解除安裝

```zsh
rm -rf ~/.zsh-smart-complete
```

## 版本歷史

請見 [CHANGELOG](./CHANGELOG.zh-TW.md) 取得完整歷史。GitHub Release 的發布說明即是從這些多語言 CHANGELOG 檔案（en / zh-CN / zh-TW / ja / ko）提取。

## 測試

```zsh
zsh tests/test-config.zsh
zsh tests/test-history.zsh
zsh tests/test-suggest.zsh
zsh tests/test-ranking.zsh
zsh tests/test-atuin.zsh
zsh tests/test-zle.zsh
zsh tests/test-menu.zsh
zsh tests/test-integration.zsh
```

**測試彙總 (v2.2.0)：** 8 個測試檔案共 359 項全部通過，0 失敗。

端到端（真實 ZLE 鍵位）驗證用 tmux `capture-pane` 讀**真實螢幕**完成，
13 項斷言全綠，涵蓋「打字即彈清單」「候選收窄時清單仍在」「單候選讓位給灰字」
「右箭頭兩種編碼都能接受」「`Alt+→` 三種編碼都只接受一個詞（用 `echo alpha beta`
探針，以命令輸出判定緩衝區內容，而非回顯的行）」「開關往返」「Tab 補全仍可用」。
同一套斷言在 v2.1.6 上只過 6/13——即「打字即彈選單」當時確實不存在。
方法沉澱在技能 `headless-pty-zle-verify`。

## 授權

MIT — 見 [LICENSE](./LICENSE)。
