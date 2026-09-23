# zsh-smart-complete

> 一個現代化的智慧補全與建議層，專為 Zsh 設計。
> 作為未來獨立 shell 的前端引擎。
>
> **v2.2.11** — 不改 `~/.zshrc` 也能調，路徑彈窗對標 autocomplete。安裝器現在會在外掛旁放一個 `zsc-settings` 小工具（wizard / list / get / set / edit / reset / path / init，均依型別校驗），把覆蓋項寫入外掛讀取先於預設值的檔案。即時彈窗路徑部分也變成 autocomplete 風格：從第一個段字元就列（`/u`、`~/l`、`cd /usr/`），裸 `/` 立即列目錄，單一匹配也會在內聯灰字旁畫 1 行彈窗。非路徑詞保持兩字元門檻；用 `SMART_MENU_MIN_MATCHES=2` 恢復。

[English](./README.md) · [简体中文](./README.zh-CN.md) · [繁體中文](./README.zh-TW.md) · [日本語](./README.ja.md) · [한국어](./README.ko.md)

## 狀態

| 管道 | 狀態 |
| ------ | ------ |
| 建置與測試 (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| 釋出 | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| 版本 | 2.2.11 |

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
curl -fsSL https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh | bash
```
互動提示從 `/dev/tty` 讀取，所以即使 stdin 就是腳本本身，選單也照常等待你的輸入。

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

安裝器會先自動偵測外網 IP 歸屬地並告訴你，歸屬地用來決定**哪些候選值得出現**：中國大陸 / 沒偵測出來顯示全部候選並全部測速（**含 direct**，因為直連是否真的更快應該測出來而不是靠地區猜）；**非中國大陸則隱藏全部預置鏡像**，只留 direct——那些 ghproxy / gitclone 通道是大陸專用，在這個地區往往比直連更慢。但即使在非中國大陸，**direct 仍然照常測速**，而且兩種手動輸入始終都在：**鏡像源**（改寫 GitHub URL）或**全量代理**（匯出為 `HTTP_PROXY`/`HTTPS_PROXY`，讓 curl/git/wget 的所有請求都走它，如 `http://127.0.0.1:7890`）。預置鏡像源都標註了「適用於中國大陸」。下面這段只在非互動安裝時才需要。

```zsh
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh | SMART_INSTALL_GH_MIRROR=https://ghproxy.net/ bash
```

## 設定

在載入外掛之前設定以下變數：

```zsh
# 主開關
: ${SMART_ENABLED:=true}
# 引擎
: ${SMART_SUGGEST:=true}
: ${SMART_COMPLETE:=true}
: ${SMART_SUGGEST_STRATEGY:=history,completion}  # history,completion | history（合併預設：歷史無匹配時由補全補上，路徑輸一半也有提示）
# 歷史後端：zsh | atuin | smart-engine（未來）
: ${SMART_HISTORY_BACKEND:=zsh}
# 介面
: ${SMART_INLINE:=true}
: ${SMART_SUGGEST_COLOR:=auto}       # auto = 256 色終端用 fg=110，否則 fg=8

# 打字即彈候選清單（zsh-autocomplete 那一半）
: ${SMART_MENU:=true}
: ${SMART_MENU_MIN_PREFIX_CMD:=2}     # 命令列首詞至少幾個字元才列
: ${SMART_MENU_MIN_PREFIX:=2}         # 參數詞至少幾個字元才列（以最後一個 "/" 之後計算，
                                      # 0 = 空格後也列）
: ${SMART_MENU_MIN_MATCHES:=1}        # 觸發即時彈窗的最少候選數（1 = 單匹配也彈，對標 autocomplete）
: ${SMART_MENU_MAX_MATCHES:=100}       # 候選多於此數就不列（同時避開超大目錄與 zsh 的「是否顯示全部 N 項」提示）
: ${SMART_MENU_MAX_PREFIX:=64}
: ${SMART_MENU_HISTORY_KEYS:=false}  # true = 行內非空時 ↑/↓ 依前綴搜尋歷史
: ${SMART_MENU_SINGLE_COLUMN:=false} # true = 每行一個候選（可選：會失去描述/著色/模糊匹配）；false = zsh 原生網格
: ${SMART_MENU_LISTER:=builtin}       # 清單由誰畫：builtin = 本外掛；fzf-tab = 本外掛不畫，交給外部浮動選擇器
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

### 單列彈窗（可選）

`SMART_MENU_SINGLE_COLUMN=true` 會把輸入即時彈窗改成**每行一個候選**，不再使用 zsh 原生的
多欄網格。它**預設關閉，且是刻意如此**——開啟前值得先看這幾條：

- 垂直清單只能靠**自行產生候選**來畫（無法可靠截取 compsys 的候選：把 `compadd` 換成函式會讓
  若干 zsh 版本完全不再加入候選，已實測）。因此該模式**繞過了 `_main_complete`**，它涵蓋的
  場景會失去候選**描述**、`list-colors` 著色、分組，以及你的
  `zstyle ':completion:*' matcher-list`——文件裡那條模糊匹配**不適用於**產生的候選。
- 只會產生指令 / 函式 / 別名 / 內建、檔案系統路徑與 `cd` 最近目錄。其餘場景（git 子指令、
  ssh 主機、`--選項`、`sudo …`）在此拿不到候選，會退回原生網格，因此**彈窗會在輸入過程中
  變形**——很容易被誤認為「又多出一個清單」。
- 超過終端寬度的候選會被截斷到一行（沒有省略號）。

機制是算術：每條*顯示*字串都被填充（或截斷）到恰好 `COLUMNS` 寬，因此只能容下一欄。輸入詞
在被當成 glob 之前會先轉義，所以檔名裡的 `[` 不會把彈窗弄壞（開頭的 `~/` 保持不轉義，
`~/…` 候選照常運作）。

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

### 清單由誰畫？（二選一）

兩個補全清單器都「有權」繪製，所以「同時出現兩個清單」不是任何一方單獨能修的 bug——必須有一方
停下來。`SMART_MENU_LISTER` 決定歸屬：

| 取值 | 結果 |
|---|---|
| `builtin`（預設） | 仍由本外掛驅動 zsh 的清單，和以前一樣 |
| `fzf-tab` | 本外掛**什麼都不畫**，畫面上只剩外部的浮動選擇器 |

它**不會**替你安裝 fzf-tab——它只是讓**本外掛**停止畫清單，於是你裝的另一個清單器成為唯一在畫的
那個。行內灰色建議不受影響：交出去的只有候選清單。選了 `fzf-tab` 後，Tab 裡也不再設定
`zstyle ':completion:*' menu select`，因為 zsh 的可選擇選單本身也是搶佔同一塊畫面的清單器。

```zsh
smart-lister                       # 現在歸誰
smart-lister builtin | fzf-tab     # 在目前 shell 裡切換
```

被接受的拼寫如下：

| 表示「本外掛」 | 表示「交出去」 |
|---|---|
| `builtin` `smart` `internal` `native` `built-in` `on` `yes` `true` `1` | `fzf-tab` `fzf_tab` `fzf` `ftb` `external` `none` `off` `no` `false` `0` |

`off` 的意思是「**本外掛的**清單關掉」（即交出去），而不是「完全沒有清單」——後者是
`SMART_MENU=false`。無法辨識的**取值**會退回 `builtin`（打錯字不能把彈窗靜默弄不見）並會被
**報告**出來；而 `smart-lister` 的**參數**打錯會**報錯並回傳非零**，所以 `smart-lister fzf-tb`
再也不會看起來像切換成功了。

出問題時用 `smart-doctor`：它會印出目前的歸屬；如果清單被交給了一個**並未載入**的選擇器，它會
明確指出，並**把它當作最終結論**——因為「什麼都畫不出來」比「出現兩個清單」更糟。

### 同時彈出兩個候選清單？

如果畫面上同時出現兩個清單，`smart-doctor` 會把所有已知「清單器」的指紋印出來，讓這件事
從「爭論」變成「可讀」：

```zsh
smart-doctor
```

它會報告 `_main_complete` / `compadd` / `_complete` 是否仍是 zsh 原生入口、是否載入了
`zsh-autocomplete` / `zsh-autosuggestions` / `fzf-tab` / 語法高亮、每個鍵盤表裡 `Tab`
歸誰、哪些 zstyle 能開啟清單、以及本外掛自身的狀態——最後給一句結論。**唯讀**，因此在
半壞掉的 shell 裡也能安全執行。

### 安裝器的可選設定（互動式）

安裝器會逐項詢問：fzf-tab、單列版面、最近目錄、↑/↓ 歷史搜尋、zsh-vi-mode、以及建議來源，
並把回答寫進 `~/.zshrc` 的一個受管區塊。該區塊刻意位於**外掛載入之前**——因為
`SMART_MENU_HISTORY_KEYS` 這類選項是在外掛安裝按鍵綁定的**那一刻**被讀取的，寫在載入之後
會被靜默忽略。重複執行只會重寫該區塊；`NONINTERACTIVE=1` 則全部取文件預設值。

fzf-tab 預設**關閉**（需主動勾選）；一旦啟用，會強制關掉內建的可選擇選單——兩者都是補全
**清單器**，同時開啟正是兩個彈窗搶同一塊畫面的由來。

## 執行時命令

```zsh
smart-status      # 印出目前狀態 + 設定
smart-disable     # 停用外掛
smart-enable      # 重新啟用
smart-reindex     # 強制重建歷史索引
smart-menu on     # 開啟打字即彈候選清單
smart-menu off    # 關閉（行內灰字建議不受影響）
smart-menu status # 檢視選單設定與上次列舉結果
smart-doctor      # 印出「第二個候選清單」的所有指紋（還有誰在畫清單）
smart-lister builtin|fzf-tab  # 選擇清單由誰畫（fzf-tab = 本外掛停止繪製）
smart-recent on|off|status # 最近目錄候選 + `cd ` 空詞列表
```

## 本地設定腳本

安裝器會建立一個使用者設定檔與一個用來管理它的小指令列工具，讓你不必更動 `~/.zshrc` 就能隨時調整外掛。檔案位於：

```
${SMART_USER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh-smart-complete/settings.zsh}
```

安裝後隨時執行 `zsc-settings`（安裝器會把它軟鏈到 `~/.local/bin/zsc-settings`，請確認該目錄在 `PATH` 中，或直接用完整路徑呼叫腳本）：

| 指令 | 作用 |
| --- | --- |
| `zsc-settings` | 互動精靈——選一項設定，輸入新值 |
| `zsc-settings list` | 列出每一項設定及其目前生效值 |
| `zsc-settings get KEY` | 印出某一項設定的生效值 |
| `zsc-settings set KEY VALUE` | 校驗並寫入一項設定 |
| `zsc-settings edit` | 用 `$EDITOR` 開啟設定檔 |
| `zsc-settings reset [KEY]` | 刪除一條覆寫（或全刪）→ 回到預設值 |
| `zsc-settings path` | 印出設定檔路徑 |
| `zsc-settings init` | （重新）產生帶註解預設值的檔案 |

設定以純 `KEY='VALUE'` 行寫入。外掛會**先於**內建預設值 source 此檔，因此你寫入的任何值都會覆寫預設值。修改某值後，請**重啟 zsh**（例如執行 `exec zsh`）使其生效。`set` 會依設定類型（bool / int / enum / path）校驗取值，拒絕非法輸入。若要改用其他檔案，可在 zsh 啟動前把 `SMART_USER_CONFIG` 指向它。

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
zsh tests/test-repaint.zsh
bash tests/test-installer-options.sh
```

**測試彙總 （v2.2.11）：** 12 個測試檔案共 804 項全部通過，0 失敗。
安裝器在清理 `~/.zshrc` 之後，現在還會**掃描其它啟動檔**（`.zprofile`、`.zshenv`、`conf.d/*.zsh`、`.zshrc.d/*`、`/etc/zsh/zshrc`）中是否仍有 `zsh-autocomplete` / `zsh-autosuggestions` 的載入行，並用精確的 `檔案:行號` **警告**使用者手動清理——它從不修改這些檔案。詳見 CHANGELOG 的 `[v2.2.5]`。


端到端（真實 ZLE 鍵位）驗證用 tmux `capture-pane` 讀**真實螢幕**完成，
49 項斷言全綠，涵蓋「打字即彈清單」「候選收窄時清單仍在」「單候選讓位給灰字」
「右箭頭兩種編碼都能接受」「`Alt+→` 三種編碼都只接受一個詞（用 `echo alpha beta`
探針，以命令輸出判定緩衝區內容，而非回顯的行）」「開關往返」「Tab 補全仍可用」。
同一套斷言在 v2.1.6 上過 24/49（其中 1 條在那裡根本走不到：它所在段落因前一條失敗而中止）——當時「打字即彈選單」確實不存在，`SS3` 與 `Alt+→` 的編碼
是死的，`Tab` 後按 `Enter` 會被吞掉，最近目錄不會列出，清單器開關與單列版面也都還沒有。這 24
條通過裡有**若干條是空過**——它們斷言「沒有畫任何清單」，而 v2.1.6 根本不會畫清單。基線必須
實跑、而不能按舊數字按比例換算，原因就在這裡。
e2e 還包含一條「緩衝區完整性」斷言：逐字輸入後提示字行必須與鍵入內容完全一致，
並以**真正執行的命令**的輸出交叉驗證——因為「每畫一次候選清單就吞掉一個按鍵」
這類靜默丟鍵，能騙過所有「只看螢幕」的檢查。

程式碼隨倉庫提供（無 `tmux` 時自動跳過）：

```zsh
./tests/e2e-tmux.sh                              # 49 項斷言
./tests/e2e-tmux.sh /tmp/zsc-v216               # 對舊版本做 A/B
```

方法沉澱在技能 `headless-pty-zle-verify`。

`tests/test-repaint.zsh` 覆蓋 tmux 那套**結構上看不到**的部分：zsh 每次按鍵真正寫
給終端的位元組。tmux 會把「換行 + 游標上移」這一對抵消掉，所以無論外掛是否在每次按鍵
時做一次帶捲動的重繪，它的螢幕**和**回捲區都完全一樣。該測試用 `zsh/zpty` 驅動真實的
`zsh -i` 並讀取原始位元組流，只釘一條不變式：**一次按鍵必須留在同一行**——不出現換行、
不出現縱向游標移動、不出現清屏。兩行提示字元下實測一次按鍵：

| 建置 | 位元組 | 帶捲動的換行 |
| --- | --- | --- |
| 每次按鍵都重繪 | 96 | 有——而且連灰字**和**彈窗都關掉時仍有 32 位元組（原生 zsh 是 1） |
| 本版本 | 33 | 無——兩者都關時 1 位元組，與原生 zsh 完全一致 |

它在舊建置上失敗、在本建置上通過，因此將來若有人把重繪加回來，是 CI 先發現，而不是使用者。
詳見 CHANGELOG `[v2.2.10]`。

## 授權

MIT — 見 [LICENSE](./LICENSE)。
