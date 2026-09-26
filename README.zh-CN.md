# zsh-smart-complete

> 一个现代化的智能补全和建议层，专为 Zsh 设计。
> 作为未来独立 shell 的前端引擎。
>
> **v2.4.1** — 幽灵建议在 zsh 5.8 和 5.8.1 上保住了颜色：恰恰是给它起名字的那个标记把属性删掉了；zsh 版本矩阵在三个镜像上全绿；而 CI 变红时会公布每一条失败的断言而不是其中一条——这样下面引用的断言数量就能对着做出该测量的那次运行核对。

[English](./README.md) · [简体中文](./README.zh-CN.md) · [繁體中文](./README.zh-TW.md) · [日本語](./README.ja.md) · [한국어](./README.ko.md)

## 状态

| 渠道 | 状态 |
| ------ | ------ |
| 构建与测试 (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| 发布 | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| 版本 | 2.4.1 |

## 为什么选择我们

同时替换 `zsh-autocomplete` 和 `zsh-autosuggestions`，采用简洁的模块化架构，为演变为独立 shell 而设计。

- **两部分合为一体（v2.2.0）** — 打字时**立即弹出候选列表**（zsh-autocomplete 的行为），同时保留行内灰字建议，`→` 全量接受、`Alt+→` 一次接受一个词（zsh-autosuggestions 的行为）。同一个插件、同一套键位、两个通道，这正是"两个插件互相冲突"的根本解法。
- **零外部依赖** — 核心插件自包含；可选 Atuin 增强。
- **箭头键全编码绑定** — `ESC [ C` 与 `ESC O C`（应用光标键模式，`TERM=xterm-256color` 下终端实际发送的形式）都绑定，不会出现"灰字在、右箭头没反应"。
- **与语法高亮兼容** — 最多只占用一条 `region_highlight` 条目，且只移除自己那条，不会覆盖其他 highlighter。在 zsh 5.9 及以上，该条目额外带有 `memo=zsh-smart-complete:suggestion` 标记；更早的版本上不写这个标记，因为在那些版本上写它会让这条高亮失去颜色。

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
curl -fsSL https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh | bash
```
交互提示从 `/dev/tty` 读取，所以即使 stdin 就是脚本本身，菜单也照常等待你的输入。

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

安装器会先自动检测外网 IP 归属地并告诉你，归属地用来决定**哪些候选值得出现**：中国大陆 / 没检测出来显示全部候选并全部测速（**含 direct**，因为直连是否真的更快应该测出来而不是靠地区猜）；**非中国大陆则隐藏全部预置镜像**，只留 direct——那些 ghproxy / gitclone 通道是大陆专用，在这个地区往往比直连更慢。但即使在非中国大陆，**direct 仍然照常测速**，而且两种手动输入始终都在：**镜像源**（改写 GitHub URL）或**全量代理**（导出为 `HTTP_PROXY`/`HTTPS_PROXY`，让 curl/git/wget 的所有请求都走它，如 `http://127.0.0.1:7890`）。预置镜像源都标注了「适用于中国大陆」。下面这段只在非交互安装时才需要。 手工输入的镜像（或用 `SMART_INSTALL_GH_MIRROR` 传入的值）必须是 `https://` 地址：抓回来的脚本正是通过这个地址被执行的，所以明文 `http://` 一律拒绝，而不是照单全收。

```zsh
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh | SMART_INSTALL_GH_MIRROR=https://ghproxy.net/ bash
```

## 配置

在加载插件之前设置以下变量：

```zsh
# 主开关
: ${SMART_ENABLED:=true}
# 引擎
: ${SMART_SUGGEST:=true}
: ${SMART_COMPLETE:=true}
: ${SMART_SUGGEST_STRATEGY:=history,completion}  # history,completion | history（合并默认：历史无匹配时由补全补上，路径输一半也有提示）
# 历史后端：zsh | atuin | smart-engine（未来）
: ${SMART_HISTORY_BACKEND:=zsh}
# 界面
: ${SMART_INLINE:=true}
: ${SMART_SUGGEST_COLOR:=auto}       # auto = 256 色终端用 fg=110，否则 fg=8

# 打字即弹候选列表（zsh-autocomplete 那一半）
: ${SMART_MENU:=true}
: ${SMART_MENU_MIN_PREFIX_CMD:=2}     # 命令行首词至少几个字符才列
: ${SMART_MENU_MIN_PREFIX:=2}         # 参数词至少几个字符才列（按最后一个 "/" 之后算，
                                      # 0 = 空格后也列）
: ${SMART_MENU_MIN_MATCHES:=1}        # 触发实时弹窗的最少候选数（1 = 单匹配也弹，对标 autocomplete）
: ${SMART_MENU_MAX_MATCHES:=100}       # 候选多于此数就不列（既避开超大目录，也避开 zsh 的「是否显示全部 N 项」提示）
: ${SMART_MENU_MAX_PREFIX:=64}
: ${SMART_MENU_HISTORY_KEYS:=false}  # true = 行内非空时 ↑/↓ 按前缀搜索历史
: ${SMART_MENU_SINGLE_COLUMN:=false} # true = 每行一个候选（可选：会失去描述/着色/模糊匹配）；false = zsh 原生网格
: ${SMART_MENU_LISTER:=builtin}       # 列表由谁画：builtin = 本插件；fzf-tab = 本插件不画，交给外部浮动选择器
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

### 单列弹窗（可选）

`SMART_MENU_SINGLE_COLUMN=true` 会把打字即时弹窗改成**每行一个候选**，不再使用 zsh 原生的
多列网格。它**默认关闭，且是刻意如此**——开启前值得先看这几条：

- 竖向列表只能靠**自己生成候选**来画（无法可靠截获 compsys 的候选：把 `compadd` 换成函数会让
  若干 zsh 版本彻底不再添加候选，已实测）。因此该模式**绕过了 `_main_complete`**，它覆盖的
  场景会失去候选**描述**、`list-colors` 着色、分组，以及你的
  `zstyle ':completion:*' matcher-list`——文档里那条模糊匹配**不适用于**生成的候选。
- 只生成命令 / 函数 / 别名 / 内建、文件系统路径与 `cd` 最近目录。凡是 shell 还在「选命令」的
  位置都会生成命令候选——行首，以及 `|`、`&&`、`;` 之后、或 `sudo` 这类命令包装词之后；最近目录
  对已输入的前缀也生效，不再只在空词时列出。其余场景（git 子命令、ssh 主机、`--选项`、`~用户`，
  以及包装词已经选了命令之后的位置，如 `sudo git`）在这里拿不到候选，会兜底回原生网格，于是
  **弹窗会在打字过程中变形**——很容易被误认为「又冒出一个列表」。
- 超过终端宽度的候选会被截断到一行（没有省略号）。

机制是算术：每条*显示*字符串都被填充（或截断）到恰好 `COLUMNS` 宽，因此只能容下一列。输入词
在被当成 glob 或前缀模式之前会先转义，所以文件名里的 `[` 不会把弹窗弄坏，`#` 也不会把它扩大成
一个模式（开头的 `~/` 保持不转义，`~/…` 候选照常工作）。

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

### 列表由谁画？（二选一）

两个补全列表器都「有权」绘制，所以「同时出现两个列表」不是任何一方单独能修的 bug——必须有一方
停下来。`SMART_MENU_LISTER` 决定归属：

| 取值 | 结果 |
|---|---|
| `builtin`（默认） | 仍由本插件驱动 zsh 的列表，和以前一样 |
| `fzf-tab` | 本插件**什么都不画**，屏幕上只剩外部的浮动选择器 |

它**不会**替你安装 fzf-tab——它只是让**本插件**停止画列表，于是你装的另一个列表器成为唯一在画的
那个。行内灰色建议不受影响：交出去的只有候选列表。选了 `fzf-tab` 后，Tab 里也不再设置
`zstyle ':completion:*' menu select`，因为 zsh 的可选择菜单本身也是一个抢占同一块屏幕的列表器。

```zsh
smart-lister                       # 现在归谁
smart-lister builtin | fzf-tab     # 在当前 shell 里切换
```

被接受的拼写如下：

| 表示「本插件」 | 表示「交出去」 |
|---|---|
| `builtin` `smart` `internal` `native` `built-in` `on` `yes` `true` `1` | `fzf-tab` `fzf_tab` `fzf` `ftb` `external` `none` `off` `no` `false` `0` |

`off` 的意思是「**本插件的**列表关掉」（即交出去），而不是「完全没有列表」——后者是
`SMART_MENU=false`。无法识别的**取值**会退回 `builtin`（打错字不能把弹窗静默弄没）并会被
**报告**出来；而 `smart-lister` 的**参数**写错会**报错并返回非零**，所以 `smart-lister fzf-tb`
再也不会看起来像切换成功了。

出问题时用 `smart-doctor`：它会打印当前的归属；如果列表被交给了一个**并未加载**的选择器，它会
明确指出来，并**把它作为最终结论**——因为「什么都画不出来」比「出现两个列表」更糟。

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
smart-lister builtin|fzf-tab  # 选择列表由谁画（fzf-tab = 本插件停止绘制）
smart-recent on|off|status # 最近目录候选 + `cd ` 空词列表
```

## 本地设置脚本

安装器会创建一个用户设置文件和一个用于管理它的小命令行工具，这样你无需改动 `~/.zshrc` 即可随时调整插件。文件位于：

```
${SMART_USER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh-smart-complete/settings.zsh}
```

安装后随时运行 `zsc-settings`（安装器会把它软链到 `~/.local/bin/zsc-settings`，请确保该目录在 `PATH` 中，或直接用完整路径调用脚本）：

| 命令 | 作用 |
| --- | --- |
| `zsc-settings` | 交互向导——选一项设置，输入新值 |
| `zsc-settings list` | 列出每一项设置及其当前生效值 |
| `zsc-settings get KEY` | 打印某一项设置的生效值 |
| `zsc-settings set KEY VALUE` | 校验并写入一项设置 |
| `zsc-settings edit` | 用 `$EDITOR` 打开设置文件 |
| `zsc-settings reset [KEY]` | 删除一条覆盖（或全删）→ 回到默认值 |
| `zsc-settings path` | 打印设置文件路径 |
| `zsc-settings init` | （重新）生成带注释默认值的文件 |

设置以纯 `KEY='VALUE'` 行写入。插件会**先于**内置默认值 source 此文件，因此你写入的任何值都会覆盖默认值。修改某值后，请**重启 zsh**（例如运行 `exec zsh`）使其生效。`set` 会按设置类型（bool / int / enum / path）校验取值，拒绝非法输入。若要改用其他文件，可在 zsh 启动前把 `SMART_USER_CONFIG` 指向它。

## 卸载

```zsh
./install.sh --uninstall
# 用一行命令安装时 argv 传不进去，可以用环境变量：
curl -fsSL https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh | SMART_UNINSTALL=1 bash
```

它只删除安装器写入的东西——`~/.zshrc` 里两个受管理的块、插件目录、`settings.zsh`
和我们创建的 `zsc-settings` 符号链接——并且在动手前先询问（无头运行把
`SMART_UNINSTALL=1` 本身就当作确认）。编辑 `~/.zshrc` 之前会先生成
`~/.zshrc.bak.<时间戳>`；如果这份备份做不出来，卸载会拒绝修改该文件。

安装器可能装过的包（fzf、starship、atuin、zinit）会保持已安装，你的
`starship.toml` 和所有 `.bak.*` 文件同样保留：它们属于 shell，不属于这个插件。
卸载后请重启 zsh。

## 版本历史

请见 [CHANGELOG](./CHANGELOG.zh-CN.md) 获取完整历史。GitHub Release 的发布说明即从这些多语言 CHANGELOG 文件（en / zh-CN / zh-TW / ja / ko）提取。

## 测试

```zsh
./tests/run-all.sh            # 跑全部套件，每个一行
./tests/run-all.sh -v         # 附带完整输出
./tests/run-all.sh menu       # 只跑名字匹配的套件
./tests/run-all.sh --list     # 列出将要跑哪些
```

**测试汇总:** `./tests/run-all.sh` 会跑完全部套件，并打印实测的文件数与断言数；全部通过，0 失败。

`tests/run-all.sh` 自动**发现** `tests/test-*.zsh`（用 zsh 跑）与 `tests/test-*.sh`（用 bash 跑），因此新增测试文件不需要改别的地方——CI 原先手写列出十二个文件，旁边正是那句自白：没被列进去的新文件永远静默不跑。它同时汇总各套件的断言计数，因此报告里的数字每次运行都是实测值。

其中一个套件 `tests/test-perf.zsh` 断言的是墙钟时间上限而非行为结果——本项目修掉的每一个平方阶复杂度 bug，输出都完全正确，唯一的症状是耗时数秒。

`install.sh` 与 `install-entware.sh` 各自包含一段由 `lib/install/core.sh` 生成的代码块（也就是两个安装器里完全相同的那批函数），这正是两份文件仍能作为独立脚本被 `curl … | bash` 执行的原因。要改这部分共享行为：编辑 `lib/install/core.sh`，运行 `tools/build-installers.sh`，然后把两个安装器一起提交。CI 跑的是 `tools/build-installers.sh --check`；`tests/test-installer-shared.sh` 覆盖两个文件之间剩下的约定，包括那份“仍然刻意重复”的函数清单。

安装器在清理 `~/.zshrc` 之后，现在还会**扫描其它启动文件**（`.zprofile`、`.zshenv`、`conf.d/*.zsh`、`.zshrc.d/*`、`/etc/zsh/zshrc`）中是否仍有 `zsh-autocomplete` / `zsh-autosuggestions` 的加载行，并用精确的 `文件:行号` **警告**用户手动清理——它从不修改这些文件。详见 CHANGELOG 的 `[v2.2.5]`。


端到端（真实 ZLE 键位）验证用 tmux `capture-pane` 读**真实屏幕**完成，
51 项断言全绿，覆盖"打字即弹列表""候选收窄时列表仍在""单候选让位给灰字"
"右箭头两种编码都能接受""`Alt+→` 三种编码都只接受一个词（用 `echo alpha beta`
探针，以命令输出判定缓冲区内容，而非回显的行）""开关往返""Tab 补全仍可用"。
脚本随仓库提供（无 `tmux` 时自动跳过）：

```zsh
./tests/e2e-tmux.sh                              # 51 项断言
./tests/e2e-tmux.sh /tmp/zsc-v216               # 对旧版本做 A/B
```

同一套断言在 v2.1.6 上过 24/49——那是它只有 49 项断言时的数字（其中 1 条在那里根本走不到：它所在段落因前一条失败而中止），此后新增的两条检查的是单列列表，而 v2.1.6 根本不画单列列表。当时「打字即弹菜单」确实不存在，`SS3` 与 `Alt+→` 的编码
是死的，`Tab` 后按 `Enter` 会被吞掉，最近目录不会列表，列表器开关与单列布局也都还没有。这 24
条通过里有**若干条是空过**——它们断言「没有画任何列表」，而 v2.1.6 根本不会画列表。基线必须
实跑、而不能按旧数字按比例换算，原因就在这里。
e2e 还包含一条「缓冲区完整性」断言：逐字输入后提示符行必须与键入内容完全一致，
并以**真正执行的命令**的输出交叉验证——因为「每画一次候选列表就吞掉一个按键」
这类静默丢键，能骗过所有「只看屏幕」的检查。

方法沉淀在技能 `headless-pty-zle-verify`。

`tests/test-repaint.zsh` 覆盖 tmux 那套**结构上看不到**的部分：zsh 每次按键真正写
给终端的字节。tmux 会把"换行 + 光标上移"这一对抵消掉，所以无论插件是否在每次按键时
做一次带滚屏的重绘，它的屏幕**和**回滚区都完全一样。该测试用 `zsh/zpty` 驱动真实的
`zsh -i` 并读取原始字节流，只钉一条不变式：**一次按键必须留在同一行**——不出现换行、
不出现纵向光标移动、不出现清屏。两行提示符下实测一次按键：

| 构建 | 字节 | 带滚屏的换行 |
| --- | --- | --- |
| 每次按键都重绘 | 96 | 有——而且连灰字**和**弹窗都关掉时仍有 32 字节（原生 zsh 是 1） |
| 本版本 | 33 | 无——两者都关时 1 字节，与原生 zsh 完全一致 |

它在旧构建上失败、在本构建上通过，因此将来若有人把重绘加回来，是 CI 先发现，
而不是用户。详见 CHANGELOG `[v2.2.10]`。

## 许可证

MIT — 见 [LICENSE](./LICENSE)。
