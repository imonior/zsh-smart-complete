# zsh-smart-complete

> 一个现代化的智能补全和建议层，专为 Zsh 设计。
> 作为未来独立 shell 的前端引擎。
>
> **v2.2.3** — 最新发布：打字即时弹窗改为**单列多行**（每行一个候选，不再是网格）；`Delete` 不再留下残影；新增 `smart-doctor`，一次打印出“第二个候选列表”的所有指纹；安装器逐项询问可选组件（fzf-tab / 单列 / 最近目录 / 历史键 / vi-mode），并把回答写进 `~/.zshrc`。

[English](./README.md) · [简体中文](./README.zh-CN.md) · [繁體中文](./README.zh-TW.md) · [日本語](./README.ja.md) · [한국어](./README.ko.md)

## 状态

| 渠道 | 状态 |
| ------ | ------ |
| 构建与测试 (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| 发布 | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| 版本 | 2.2.3 |

## 为什么选择我们

同时替换 `zsh-autocomplete` 和 `zsh-autosuggestions`，采用简洁的模块化架构，为演变为独立 shell 而设计。

- **两部分合为一体（v2.2.0）** — 打字时**立即弹出候选列表**（zsh-autocomplete 的行为），同时保留行内灰字建议，`→` 全量接受、`Alt+→` 一次接受一个词（zsh-autosuggestions 的行为）。同一个插件、同一套键位、两个通道，这正是"两个插件互相冲突"的根本解法。
- **零外部依赖** — 核心插件自包含；可选 Atuin 增强。
- **箭头键全编码绑定** — `ESC [ C` 与 `ESC O C`（应用光标键模式，`TERM=xterm-256color` 下终端实际发送的形式）都绑定，不会出现"灰字在、右箭头没反应"。
- **与语法高亮兼容** — 使用 `#zsh-smart-complete:suggestion` 标记，不覆盖其他 highlighter。

## 架构

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
        history/history         (用户 compinit)
                                       │
                                   engine/menu
                              （打字即弹候选列表）
               │
      zsh fc   │   atuin (可选)   │   smart-engine (未来)
               └───────────────────┴───────────────────┘
                           │
                     display/
                 region_highlight
```

## 快速开始

### 前置条件

让 Zsh 本身拥有 `compinit`：

```zsh
export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=1000000
export SAVEHIST=1000000
setopt appendhistory sharehistory histignorealldups

autoload -Uz compinit
compinit
```

### 安装

> ⚠️ 本插件同时替换 `zsh-autocomplete` 和 `zsh-autosuggestions`。

#### 方式 A — 一键安装器（推荐）

```zsh
bash <(curl -fsSL https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh)
```

#### 方式 B — Zinit（手动）

```zsh
zinit light imonior/zsh-smart-complete
```

#### 方式 C — 手动克隆

```zsh
git clone https://github.com/imonior/zsh-smart-complete.git ~/.zsh-smart-complete
echo 'source ~/.zsh-smart-complete/zsh-smart-complete.plugin.zsh' >> ~/.zshrc
```

#### 国内代理加速

```zsh
SMART_INSTALL_GH_MIRROR=https://ghproxy.net/ bash -c "$(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh)"
```

## 配置

在加载插件之前设置以下变量：

```zsh
# 主开关
: ${SMART_ENABLED:=true}
# 引擎
: ${SMART_SUGGEST:=true}
: ${SMART_COMPLETE:=true}
: ${SMART_SUGGEST_STRATEGY:=history}  # history | history,completion（completion 还会用补全系统作建议来源）
# 历史后端：zsh | atuin | smart-engine（未来）
: ${SMART_HISTORY_BACKEND:=zsh}
# 界面
: ${SMART_INLINE:=true}
: ${SMART_SUGGEST_COLOR:=fg=8}

# 打字即弹候选列表（zsh-autocomplete 那一半）
: ${SMART_MENU:=true}
: ${SMART_MENU_MIN_PREFIX_CMD:=2}     # 命令行首词至少几个字符才列
: ${SMART_MENU_MIN_PREFIX:=1}         # 参数词至少几个字符才列（0 = 空格后也列）
: ${SMART_MENU_MIN_MATCHES:=2}        # 候选少于这个数就不列（单个候选由灰字承担）
: ${SMART_MENU_MAX_MATCHES:=100}       # 候选多于此数就不列（既避开超大目录，也避开 zsh 的「是否显示全部 N 项」提示）
: ${SMART_MENU_MAX_PREFIX:=64}
: ${SMART_MENU_HISTORY_KEYS:=false}  # true = 行内非空时 ↑/↓ 按前缀搜索历史
: ${SMART_MENU_SINGLE_COLUMN:=true}  # true = 每行一个候选（单列）；false = zsh 原生网格
# 节流：默认关闭。实测每次列举只要 10~30ms，没什么可降的；
# 这个开关是留给「持续很贵」的补全的。开启后，耗时 ≥ SLOW_MS 的列举
# 会换来 COOLDOWN_KEYS 次跳过。注意：被跳过的那次按键不会重绘，
# 屏幕上的候选列表会消失——这正是默认设为 0 的原因。
: ${SMART_MENU_SLOW_MS:=250}
: ${SMART_MENU_COOLDOWN_KEYS:=0}

# 排查用：设成文件路径后，每次 tick 的决策（被闸门拒绝 / 被冷却吞掉 /
# 命中几个候选 / 花了多少毫秒）都会追加写进去。"没弹出来"到底是
# 哪种原因，屏幕上分不出来，这个日志能。
: ${SMART_MENU_DEBUG:=}

# 最近目录：补全 `cd` 参数时把你 cd 过的目录作为候选，并在 `cd ` 后的空词直接
# 列出（空词值得列表的唯一位置）。只读——消费 zsh 原生的最近目录数据库，
# 自己不记录任何东西。
: ${SMART_RECENT_PATHS:=true}
: ${SMART_RECENT_PATHS_MAX:=20}
```

同时提供具名 widget，可以像 `zsh-autosuggestions` 那样自行改键：
`smart-accept-suggestion`（整句接受，默认绑 →）、`smart-accept-word`（接受一个词，
默认绑 Alt+→）、`smart-execute-suggestion`（接受并执行该行）、
`smart-suggestion-toggle`（开关灰色建议）。设为 `SMART_MENU_HISTORY_KEYS=true` 后，
行内非空时 ↑/↓ 会按前缀搜索历史——默认关闭，因为这两个键的使用习惯很深。

## 可选增强

### 模糊匹配（由 zsh 完成，不是我们）

实时弹窗跑的就是**你自己的**补全系统，所以你配置的 matcher 会自动对它生效。
想让 `fb` 也能匹配 `foobar.txt`：

```zsh
zstyle ':completion:*' matcher-list 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
```

这里没有开关要拨——我们也不实现模糊算法，那只会和补全系统打架。

### 单列弹窗

打字即时弹窗采用**每行一个候选**，不再使用 zsh 原生的多列网格——候选名较长或共享前缀时，
可读性差别很大。设为 `SMART_MENU_SINGLE_COLUMN=false` 即退回原生网格。

候选由插件直接生成（命令 / 函数 / 别名、文件系统路径、`cd ` 最近目录），并把每一条
**显示字符串**填充**或截断**到恰好 `COLUMNS` 宽——这正是数学上只容得下一列的原因。生成器
覆盖不到的场景（git 子命令、ssh 主机名、选项串）会**兜底**交给你的补全，因此不会有任何损失。

输入词在被当成 glob 之前会先转义，因此文件名里的 `[` 不会把弹窗弄坏（开头的 `~/` 保持不转义，
`~/…` 候选照常工作）。

### 最近目录

补全 `cd` / `pushd` / `chdir` 参数时，你实际去过的目录会作为候选出现；并且在
`cd ` 后的**空词**就直接列出（空词值得列表的唯一位置）。

数据来自 zsh 原生的最近目录数据库——`cdr` 与 `~[1]` 用的是同一份。插件只**读**
它，从不写入。如果它还是空的，两行配置即可开启记录：

```zsh
autoload -Uz chpwd_recent_dirs add-zsh-hook
add-zsh-hook chpwd chpwd_recent_dirs
```

`smart-recent status` 会显示当前可用多少条。

### 同时弹出两个候选列表？

如果屏幕上同时出现两个列表，`smart-doctor` 会把所有已知“列表器”的指纹打印出来，让这件事
从「争论」变成「可读」：

```zsh
smart-doctor
```

它会报告 `_main_complete` / `compadd` / `_complete` 是否仍是 zsh 原生入口、是否加载了
`zsh-autocomplete` / `zsh-autosuggestions` / `fzf-tab` / 语法高亮、每个键盘表里 `Tab`
归谁、哪些 zstyle 能开启列表、以及本插件自身的状态——最后给一句结论。**只读**，所以在
半坏掉的 shell 里也能安全运行。

### 安装器的可选配置（交互式）

安装器会逐项询问：fzf-tab、单列布局、最近目录、↑/↓ 历史搜索、zsh-vi-mode、以及建议来源，
并把回答写进 `~/.zshrc` 的一个受管区块。该区块刻意位于**插件加载之前**——因为
`SMART_MENU_HISTORY_KEYS` 这类选项是在插件安装按键绑定的**那一刻**被读取的，写在加载之后
会被静默忽略。重复运行只会重写该区块；`NONINTERACTIVE=1` 则全部取文档默认值。

fzf-tab 默认**关闭**（需主动勾选）；一旦启用，会强制关掉内置的可选择菜单——两者都是补全
**列表器**，同时开启正是两个弹窗抢同一块屏幕的由来。

## 运行时命令

```zsh
smart-status      # 打印当前状态 + 配置
smart-disable     # 禁用插件
smart-enable      # 重新启用
smart-reindex     # 强制重建历史索引
smart-menu on     # 开启打字即弹候选列表
smart-menu off    # 关闭（行内灰字建议不受影响）
smart-menu status # 查看菜单配置与上次列举结果
smart-doctor      # 打印“第二个候选列表”的所有指纹（还有谁在画列表）
smart-recent on|off|status # 最近目录候选 + `cd ` 空词列表
```

## 卸载

```zsh
rm -rf ~/.zsh-smart-complete
```

## 版本历史

请见 [CHANGELOG](./CHANGELOG.zh-CN.md) 获取完整历史。GitHub Release 的发布说明即从这些多语言 CHANGELOG 文件（en / zh-CN / zh-TW / ja / ko）提取。

## 测试

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
bash tests/test-installer-options.sh
```

**测试汇总 (v2.2.3)：** 10 个测试文件共 538 项全部通过，0 失败。

端到端（真实 ZLE 键位）验证用 tmux `capture-pane` 读**真实屏幕**完成，
33 项断言全绿，覆盖"打字即弹列表""候选收窄时列表仍在""单候选让位给灰字"
"右箭头两种编码都能接受""`Alt+→` 三种编码都只接受一个词（用 `echo alpha beta`
探针，以命令输出判定缓冲区内容，而非回显的行）""开关往返""Tab 补全仍可用"。
脚本随仓库提供（无 `tmux` 时自动跳过）：

```zsh
./tests/e2e-tmux.sh                              # 33 项断言
./tests/e2e-tmux.sh /tmp/zsc-v216               # 对旧版本做 A/B
```

同一套断言在 v2.1.6 上过 18/33——当时「打字即弹菜单」确实不存在，`SS3` 与 `Alt+→` 的编码
是死的，`Tab` 后按 `Enter` 会被吞掉，最近目录不会列表，也没有单列布局。
e2e 还包含一条「缓冲区完整性」断言：逐字输入后提示符行必须与键入内容完全一致，
并以**真正执行的命令**的输出交叉验证——因为「每画一次候选列表就吞掉一个按键」
这类静默丢键，能骗过所有「只看屏幕」的检查。

方法沉淀在技能 `headless-pty-zle-verify`。

## 许可证

MIT — 见 [LICENSE](./LICENSE)。
