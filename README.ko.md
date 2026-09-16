# zsh-smart-complete

> Zsh 용 현대적인 스마트 완성 및 제안 레이어.
> 미래의 독립 셸 프런트엔드로 설계됨.
>
> **v2.2.3** — 최신 릴리스: 입력 중 팝업이 **단일 열**(한 줄에 후보 하나)로. `Delete` 가 잔상을 남기지 않고, `smart-doctor` 가 "두 번째 후보 목록"의 지문을 모두 출력합니다. 설치 프로그램이 선택 항목(fzf-tab / 단일 열 / 최근 디렉터리 / 기록 키 / vi-mode)을 하나씩 묻고 답변을 `~/.zshrc` 에 기록합니다.

[English](./README.md) · [简体中文](./README.zh-CN.md) · [繁體中文](./README.zh-TW.md) · [日本語](./README.ja.md) · [한국어](./README.ko.md)

## 상태

| 채널 | 상태 |
| ------ | ------ |
| 빌드 및 테스트 (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| 릴리스 | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| 버전 | 2.2.3 |

## 왜 이 플러그인인가

`zsh-autocomplete`와 `zsh-autosuggestions` 두 가지를 깔끔한 모듈 구조의 단일 플러그인으로 대체하며, 독립 셸로 진화하도록 설계했습니다.

- **두 부분, 하나의 엔진 (v2.2.0)** — 입력하는 동안 후보 목록이 **즉시 팝업**됩니다(zsh-autocomplete 동작)과 동시에 행 내부의 회색 제안은 남습니다. `→`는 전체를, `Alt+→`는 한 단어를 수락합니다(zsh-autosuggestions 동작). 하나의 플러그인, 하나의 키맵, 두 채널 — "두 플러그인이 충돌한다"는 근본적인 해결책입니다.
- **외부 의존성 없음** — 코어 플러그인은 자체 완결적이며, Atuin은 선택 사항.
- **화살표 키 모든 인코딩 바인딩** — `ESC [ C`와 `ESC O C`(애플리케이션 커서 키 모드, `TERM=xterm-256color`에서 터미널이 실제로 보내는 형식) 모두 바인딩되어 "회색 글자는 보이는데 화살표가 안 먹힌다"가 일어나지 않습니다.
- **구문 강조와 친화적** — `#zsh-smart-complete:suggestion` 태그를 사용하며 다른 하이라이터를 덮어쓰지 않습니다.

## 아키텍처

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
        history/history         (사용자 compinit)
                                       │
                                   engine/menu
                              (입력하면 팝업되는 목록)
               │
      zsh fc   │   atuin (선택)   │   smart-engine (미래)
               └───────────────────┴───────────────────┘
                           │
                     display/
                 region_highlight
```

## 빠른 시작

### 사전 조건

Zsh 자체에 `compinit`이 있도록 합니다:

```zsh
export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=1000000
export SAVEHIST=1000000
setopt appendhistory sharehistory histignorealldups

autoload -Uz compinit
compinit
```

### 설치

> ⚠️ 이 플러그인은 `zsh-autocomplete`과 `zsh-autosuggestions` **둘 다**를 대체합니다.

#### 방법 A — 원라인 설치기 (권장)

```zsh
bash <(curl -fsSL https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh)
```

#### 방법 B — Zinit

```zsh
zinit light imonior/zsh-smart-complete
```

#### 방법 C — 수동 클론

```zsh
git clone https://github.com/imonior/zsh-smart-complete.git ~/.zsh-smart-complete
echo 'source ~/.zsh-smart-complete/zsh-smart-complete.plugin.zsh' >> ~/.zshrc
```

#### 중국 본토 미러

```zsh
SMART_INSTALL_GH_MIRROR=https://ghproxy.net/ bash -c "$(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh)"
```

## 설정

플러그인을 불러오기 **전에** 다음 변수를 설정합니다:

```zsh
# 마스터 스위치
: ${SMART_ENABLED:=true}
# 엔진
: ${SMART_SUGGEST:=true}
: ${SMART_COMPLETE:=true}
: ${SMART_SUGGEST_STRATEGY:=history}  # history | history,completion (completion은 완성 시스템도 제안 소스로 사용)
# 히스토리 백엔드: zsh | atuin | smart-engine (미래)
: ${SMART_HISTORY_BACKEND:=zsh}
# UI
: ${SMART_INLINE:=true}
: ${SMART_SUGGEST_COLOR:=fg=8}

# 입력하면 팝업되는 후보 목록 (zsh-autocomplete 쪽)
: ${SMART_MENU:=true}
: ${SMART_MENU_MIN_PREFIX_CMD:=2}     # 목록 표시 전 명령어 단어 최소 문자 수
: ${SMART_MENU_MIN_PREFIX:=1}         # 인수 단어 최소 문자 수 (0 = 공백 직후에도 표시)
: ${SMART_MENU_MIN_MATCHES:=2}        # 이보다 적은 후보는 목록 비표시 (단일 후보는 회색 글자가 담당)
: ${SMART_MENU_MAX_MATCHES:=100}       # 이보다 많은 후보는 목록 비표시 (거대 디렉터리와 zsh의 "N개 모두 표시?" 프롬프트 회피)
: ${SMART_MENU_MAX_PREFIX:=64}
: ${SMART_MENU_HISTORY_KEYS:=false}  # true = 줄이 비어 있지 않을 때 ↑/↓ 접두사 히스토리 검색
: ${SMART_MENU_SINGLE_COLUMN:=true}  # true = 한 줄에 후보 하나(단일 열). false = zsh 기본 그리드
# 스로틀: 기본 끄기. 실측상 목록 가져오기는 10~30ms뿐이라 줄일 것이 없으며,
# 이 스위치는 "지속적으로 비싼" 완성을 위한 것. 켜면 SLOW_MS 이상인 목록 가져오기가
# COOLDOWN_KEYS회 스킵을 유발. 주의: 스킵된 키 입력은 재도화되지 않아 그 순간
# 화면의 목록이 사라짐 — 그래서 기본값이 0.
: ${SMART_MENU_SLOW_MS:=250}
: ${SMART_MENU_COOLDOWN_KEYS:=0}

# 디버깅용: 파일 경로를 지정하면 매 tick 결정(게이트 거부 / 쿨다운에 의한 스킵 /
# 후보 수 / 측정 밀리초)이 추가됨. "팝업 안 뜸"은 "후보 하나라 회색 글자에 양보함"과
# 구분할 수 없으므로 이 로그가 도움이 됨.
: ${SMART_MENU_DEBUG:=}

# 최근 디렉터리: `cd` 인자를 완성할 때 실제로 들어가 본 디렉터리를 후보로
# 제시하고, `cd ` 직후의 빈 단어에서는 즉시 목록을 보여 줍니다(빈 단어를
# 나열할 가치가 있는 유일한 위치). 읽기 전용이며, zsh 자체의 recent-dirs
# 데이터베이스를 소비할 뿐 아무것도 기록하지 않습니다.
: ${SMART_RECENT_PATHS:=true}
: ${SMART_RECENT_PATHS_MAX:=20}
```

이름 있는 위젯도 제공하므로 `zsh-autosuggestions`처럼 키를 다시 지정할 수
있습니다: `smart-accept-suggestion`(전체 제안 수락, 기본 →),
`smart-accept-word`(한 단어만 수락, 기본 Alt+→),
`smart-execute-suggestion`(수락 후 그 줄 실행),
`smart-suggestion-toggle`(회색 제안 켜기/끄기).
`SMART_MENU_HISTORY_KEYS=true`이면 줄이 비어 있지 않을 때 ↑/↓가 접두사 히스토리
검색이 됩니다(기본 꺼짐 — 이 키들의 사용 습관이 강하기 때문).

## 선택 확장

### 퍼지 매칭 (zsh가 하며, 이 플러그인이 아닙니다)

라이브 팝업은 **사용자 자신의** 완성 시스템을 실행하므로, 설정한 matcher가
자동으로 적용됩니다. `fb`가 `foobar.txt`에 매칭되게 하려면:

```zsh
zstyle ':completion:*' matcher-list 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
```

여기서 켤 스위치는 없습니다. 퍼지 매칭을 직접 구현하면 완성 시스템과
충돌할 뿐입니다.

### 단일 열 팝업

입력 중 팝업은 zsh 기본 다중 열 그리드 대신 **한 줄에 후보 하나**로 그립니다. 후보 이름이
길거나 접두사가 겹칠 때 가독성 차이가 큽니다. `SMART_MENU_SINGLE_COLUMN=false` 로 두면 기본
그리드로 돌아갑니다.

후보는 플러그인이 직접 생성하고(명령 / 함수 / 별칭, 파일 경로, `cd ` 최근 디렉터리) 모든
**표시 문자열**을 정확히 `COLUMNS` 폭으로 채우거나 잘라냅니다. 이것이 수학적으로 한 열만
들어가게 하는 이유입니다. 생성기가 다루지 못하는 맥락(git 하위 명령, ssh 호스트, 옵션 문자열)은
**실제 완성으로 폴백**하므로 잃는 것이 없습니다.

입력한 단어는 glob 이 되기 전에 이스케이프되므로 파일 이름의 `[` 가 팝업을 깨뜨리지 않습니다
(앞부분의 `~/` 는 이스케이프하지 않아 `~/…` 후보가 그대로 동작합니다).

### 최근 디렉터리

`cd` / `pushd` / `chdir` 인자를 완성할 때 실제로 들어가 본 디렉터리가 후보로
제시되고, `cd ` 직후의 **빈 단어**에서는 즉시 목록이 표시됩니다(빈 단어를
나열할 가치가 있는 유일한 위치).

데이터는 zsh 자체의 recent-dirs 데이터베이스이며 `cdr` 및 `~[1]`과 같은
것입니다. 플러그인은 **읽기만** 하고 아무것도 쓰지 않습니다. 아직 비어 있다면
다음 두 줄로 기록을 켤 수 있습니다:

```zsh
autoload -Uz chpwd_recent_dirs add-zsh-hook
add-zsh-hook chpwd chpwd_recent_dirs
```

`smart-recent status`로 현재 몇 개를 쓸 수 있는지 확인할 수 있습니다.

### 후보 목록이 두 개 동시에 뜨나요?

화면에 목록이 두 개 동시에 나타난다면, `smart-doctor` 가 알려진 모든 "목록 표시기"의 지문을
출력합니다. 논쟁이 아니라 읽고 판단할 수 있는 형태가 됩니다:

```zsh
smart-doctor
```

`_main_complete` / `compadd` / `_complete` 가 아직 zsh 순정 진입점인지,
`zsh-autocomplete` / `zsh-autosuggestions` / `fzf-tab` / 구문 강조가 로드되었는지, 키맵별로
`Tab` 을 누가 갖는지, 목록을 켤 수 있는 zstyle, 그리고 이 플러그인 자체의 상태를 보고하고
마지막에 판정 한 줄을 출력합니다. **읽기 전용**이라 망가진 shell 에서도 안전합니다.

### 설치 프로그램의 선택 항목(대화형)

설치 프로그램은 fzf-tab, 단일 열 레이아웃, 최근 디렉터리, ↑/↓ 기록 검색, zsh-vi-mode, 제안
출처를 하나씩 묻고 답변을 `~/.zshrc` 의 관리 블록에 기록합니다. 이 블록은 의도적으로
**플러그인 로드보다 앞**에 놓입니다. `SMART_MENU_HISTORY_KEYS` 같은 옵션은 플러그인이
키 바인딩을 설치하는 **시점**에 읽히므로, 나중에 쓰면 조용히 무시되기 때문입니다. 재실행하면
그 블록만 다시 쓰입니다. `NONINTERACTIVE=1` 에서는 문서화된 기본값을 사용합니다.

fzf-tab 은 기본 **꺼짐**(명시적 옵트인)이며, 켜면 내장 선택 메뉴를 강제로 끕니다 — 둘 다
완성 **목록 표시기**이고, 둘을 동시에 켜는 것이 바로 두 팝업이 같은 화면 영역을 다투는
원인입니다.

## 실행 시 명령

```zsh
smart-status      # 현재 상태 + 설정 출력
smart-disable     # 플러그인 비활성화
smart-enable      # 다시 활성화
smart-reindex     # 히스토리 인덱스 강제 재구성
smart-menu on     # 입력하면 팝업되는 목록 켜기
smart-menu off    # 끄기 (행 내부 회색 제안은 영향 없음)
smart-menu status # 메뉴 설정과 마지막 목록 결과 보기
smart-doctor      # "두 번째 후보 목록"의 지문을 모두 출력
smart-recent on|off|status # 최근 디렉터리 후보 + `cd ` 빈 단어 목록
```

## 제거

```zsh
rm -rf ~/.zsh-smart-complete
```

## 변경 내역

전체 기록은 [CHANGELOG](./CHANGELOG.ko.md)을 참조하세요. GitHub Release의 릴리스 노트는 이 다국어 CHANGELOG 파일(en / zh-CN / zh-TW / ja / ko)에서 추출됩니다.

## 테스트

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

**테스트 요약 (v2.2.3):** 10개 파일, 538개 어설션, 전부 통과, 0 실패.

주요 동작은 tmux 페인 안의 실제 `zsh -i`에 대해 엔드투엔드로 검증되며, 렌더링된
화면을 어설트합니다(33/33 그린). 같은 어설션은 v2.1.6에서는 **18/33** — 당시
"입력하면 팝업되는 메뉴"는 존재하지 않았고, `SS3` 와 `Alt+→` 인코딩은 죽어 있었으며,
`Tab` 후 `Enter` 는 삼켜지고, 최근 디렉터리는 나열되지 않았고, 단일 열 레이아웃도
없었습니다.
이 하니스는 저장소에 포함됩니다(`tmux` 없으면 자동 스킵):

```zsh
./tests/e2e-tmux.sh                              # 33 어설션
./tests/e2e-tmux.sh /tmp/zsc-v216               # 이전 릴리스와 A/B
```

e2e 는 "버퍼 무결성"도 검증합니다. 한 글자씩 입력한 뒤 프롬프트 줄이
입력 내용과 정확히 일치해야 하고, **실제로 실행된 명령**의 출력으로 교차
검증합니다. 목록을 그릴 때마다 키를 하나 삼키던 조용한 버그는 "화면만 보는"
모든 검사를 통과해 버리기 때문입니다.

방법은 `headless-pty-zle-verify` 스킬에 정리되어 있습니다.

## 라이선스

MIT — [LICENSE](./LICENSE) 참조.
