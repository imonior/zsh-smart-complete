# zsh-smart-complete

> 一個現代化的智慧補全與建議層，專為 Zsh 設計。
> 作為未來獨立 shell 的前端引擎。
>
> **v2.2.2** — 最新釋出：補全 `cd` 時提供最近目錄候選；`Tab` 後按 `Enter` 現在會真正執行該行；模糊匹配改為文件說明（那是 zsh 的能力，不是我們的）。

[English](./README.md) · [简体中文](./README.zh-CN.md) · [繁體中文](./README.zh-TW.md) · [日本語](./README.ja.md) · [한국어](./README.ko.md)

## 狀態

| 管道 | 狀態 |
| ------ | ------ |
| 建置與測試 (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| 釋出 | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| 版本 | 2.2.2 |

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
: ${SMART_SUGGEST_STRATEGY:=history}  # history | history,completion（completion 亦會用補全系統作為建議來源）
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
: ${SMART_MENU_MAX_MATCHES:=100}       # 候選多於此數就不列（同時避開超大目錄與 zsh 的「是否顯示全部 N 項」提示）
: ${SMART_MENU_MAX_PREFIX:=64}
: ${SMART_MENU_HISTORY_KEYS:=false}  # true = 行內非空時 ↑/↓ 依前綴搜尋歷史
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

# 最近目錄：補全 `cd` 參數時把你 cd 過的目錄作為候選，並在 `cd ` 後的空詞直接
# 列出（空詞值得列表的唯一位置）。唯讀——消費 zsh 原生的最近目錄資料庫，
# 自己不記錄任何東西。
: ${SMART_RECENT_PATHS:=true}
: ${SMART_RECENT_PATHS_MAX:=20}
```

同時提供具名 widget，可以像 `zsh-autosuggestions` 那樣自行改鍵：
`smart-accept-suggestion`（整句接受，預設綁 →）、`smart-accept-word`（接受一個詞，
預設綁 Alt+→）、`smart-execute-suggestion`（接受並執行該行）、
`smart-suggestion-toggle`（開關灰色建議）。設為 `SMART_MENU_HISTORY_KEYS=true` 後，
行內非空時 ↑/↓ 會依前綴搜尋歷史——預設關閉，因為這兩個鍵的使用習慣很深。

## 選用增強

### 模糊比對（由 zsh 完成，不是我們）

即時彈窗跑的就是**你自己的**補全系統，所以你設定的 matcher 會自動對它生效。
想讓 `fb` 也能比對到 `foobar.txt`：

```zsh
zstyle ':completion:*' matcher-list 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
```

這裡沒有開關要撥——我們也不實作模糊演算法，那只會和補全系統打架。

### 最近目錄

補全 `cd` / `pushd` / `chdir` 參數時，你實際去過的目錄會作為候選出現；並且在
`cd ` 後的**空詞**就直接列出（空詞值得列表的唯一位置）。

資料來自 zsh 原生的最近目錄資料庫——`cdr` 與 `~[1]` 用的是同一份。外掛只**讀**
它，從不寫入。如果它還是空的，兩行設定即可開啟記錄：

```zsh
autoload -Uz chpwd_recent_dirs add-zsh-hook
add-zsh-hook chpwd chpwd_recent_dirs
```

`smart-recent status` 會顯示目前可用幾筆。

## 執行時命令

```zsh
smart-status      # 印出目前狀態 + 設定
smart-disable     # 停用外掛
smart-enable      # 重新啟用
smart-reindex     # 強制重建歷史索引
smart-menu on     # 開啟打字即彈候選清單
smart-menu off    # 關閉（行內灰字建議不受影響）
smart-menu status # 檢視選單設定與上次列舉結果
smart-recent on|off|status # 最近目錄候選 + `cd ` 空詞列表
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
zsh tests/test-recent.zsh
```

**測試彙總 (v2.2.2)：** 9 個測試檔案共 438 項全部通過，0 失敗。

端到端（真實 ZLE 鍵位）驗證用 tmux `capture-pane` 讀**真實螢幕**完成，
29 項斷言全綠，涵蓋「打字即彈清單」「候選收窄時清單仍在」「單候選讓位給灰字」
「右箭頭兩種編碼都能接受」「`Alt+→` 三種編碼都只接受一個詞（用 `echo alpha beta`
探針，以命令輸出判定緩衝區內容，而非回顯的行）」「開關往返」「Tab 補全仍可用」。
同一套斷言在 v2.1.6 上過 17/29——即「打字即彈選單」當時確實不存在。
本版 e2e 新增「緩衝區完整性」斷言：逐字輸入後提示字行必須與鍵入內容完全一致，
並以**真正執行的命令**的輸出交叉驗證——因為「每畫一次候選清單就吞掉一個按鍵」
這類靜默丟鍵，能騙過所有「只看螢幕」的檢查。

方法沉澱在技能 `headless-pty-zle-verify`。

## 授權

MIT — 見 [LICENSE](./LICENSE)。
