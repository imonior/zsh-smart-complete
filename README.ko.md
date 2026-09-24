# zsh-smart-complete

> Zsh 용 현대적인 스마트 완성 및 제안 레이어.
> 미래의 독립 셸 프런트엔드로 설계됨.
>
> **v2.3.0** — 히스토리가 커졌다고 몇 초를 낼 필요가 없습니다. 8000 명령에서 제안 인덱스 재구축은 **693 ms → 30 ms**, Enter 는 인덱스 전체를 다시 훑는 것에서 도장 하나로 바뀝니다(50 명령: **9.8 s → 32 ms**); 키 입력은 메모리에 이미 있는 값을 읽으려고 fork 하지 않습니다. Entware 설치에서도 설정 블록이 실제로 들어갑니다. 추가: `./tests/run-all.sh` 가 외울 유일한 명령(스위트 자동 발견), 그리고 `tests/test-perf.zsh` —— 증상은 출력 오류가 아니라 "초"인 트리프와이어. CI 는 이제 zsh 5.7 / 5.8 / 5.9 에서 같은 스위트를 돌리고, 릴리스는 "테스트 + `VERSION` + CHANGELOG" 게이트를 지나야 합니다.

[English](./README.md) · [简体中文](./README.zh-CN.md) · [繁體中文](./README.zh-TW.md) · [日本語](./README.ja.md) · [한국어](./README.ko.md)

## 상태

| 채널 | 상태 |
| ------ | ------ |
| 빌드 및 테스트 (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| 릴리스 | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| 버전 | 2.3.0 |

## 왜 이 플러그인인가

`zsh-autocomplete`와 `zsh-autosuggestions` 두 가지를 깔끔한 모듈 구조의 단일 플러그인으로 대체하며, 독립 셸로 진화하도록 설계했습니다.

- **두 부분, 하나의 엔진 (v2.2.0)** — 입력하는 동안 후보 목록이 **즉시 팝업**됩니다(zsh-autocomplete 동작)과 동시에 행 내부의 회색 제안은 남습니다. `→`는 전체를, `Alt+→`는 한 단어를 수락합니다(zsh-autosuggestions 동작). 하나의 플러그인, 하나의 키맵, 두 채널 — "두 플러그인이 충돌한다"는 근본적인 해결책입니다.
- **외부 의존성 없음** — 코어 플러그인은 자체 완결적이며, Atuin은 선택 사항.
- **화살표 키 모든 인코딩 바인딩** — `ESC [ C`와 `ESC O C`(애플리케이션 커서 키 모드, `TERM=xterm-256color`에서 터미널이 실제로 보내는 형식) 모두 바인딩되어 "회색 글자는 보이는데 화살표가 안 먹힌다"가 일어나지 않습니다.
- **구문 강조와 친화적** — `region_highlight` 항목을 최대 하나만 차지하고 `memo=zsh-smart-complete:suggestion`으로 표시하며 자기 항목만 제거하므로 다른 하이라이터를 덮어쓰지 않습니다.

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
curl -fsSL https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh | bash
```
대화형 프롬프트는 `/dev/tty` 에서 읽으므로 stdin 이 스크립트 자체여도 메뉴가 입력을 기다립니다.

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

설치 프로그램이 외부 IP 소속을 먼저 자동 감지해 알려주며, 소속은 **어떤 후보를 보여줄지**를 결정합니다: 중국 본토 / 감지 실패라면 모든 후보를 표시하고 모든 후보(**direct 포함**)의 속도를 측정합니다(direct 가 실제로 더 빠른지는 지역으로 추측할 것이 아니라 실측해야 하기 때문입니다). **중국 본토 외라면 모든 프리셋 미러를 숨기고** direct 만 남깁니다 — 그 ghproxy / gitclone 경로는 중국 본토 전용이라 이 지역에서는 direct 보다 느린 경우가 많습니다. 다만 중국 본토 외에서도 **direct 는 여전히 속도 측정**하며, 두 가지 수동 입력도 항상 남아 있습니다: **미러 소스**(GitHub URL 재작성)와 **전체 프록시**(`HTTP_PROXY`/`HTTPS_PROXY` 로 내보내 curl/git/wget 의 모든 요청이 통과하도록 함. 예: `http://127.0.0.1:7890`). 사전 정의된 미러는 「중국 본토용」으로 표시됩니다. 아래 명령은 비대화형 설치에서만 필요합니다.

```zsh
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh | SMART_INSTALL_GH_MIRROR=https://ghproxy.net/ bash
```

## 설정

플러그인을 불러오기 **전에** 다음 변수를 설정합니다:

```zsh
# 마스터 스위치
: ${SMART_ENABLED:=true}
# 엔진
: ${SMART_SUGGEST:=true}
: ${SMART_COMPLETE:=true}
: ${SMART_SUGGEST_STRATEGY:=history,completion}  # history,completion | history (기본 조합: 기록에 없으면 완성이 제안을 채움)
# 히스토리 백엔드: zsh | atuin | smart-engine (미래)
: ${SMART_HISTORY_BACKEND:=zsh}
# UI
: ${SMART_INLINE:=true}
: ${SMART_SUGGEST_COLOR:=auto}       # auto = 256색 터미널은 fg=110, 그 외는 fg=8

# 입력하면 팝업되는 후보 목록 (zsh-autocomplete 쪽)
: ${SMART_MENU:=true}
: ${SMART_MENU_MIN_PREFIX_CMD:=2}     # 목록 표시 전 명령어 단어 최소 문자 수
: ${SMART_MENU_MIN_PREFIX:=2}         # 인수 단어 최소 문자 수 (마지막 "/" 뒤 기준,
                                      # 0 = 공백 직후에도 표시)
: ${SMART_MENU_MIN_MATCHES:=1}        # 실시간 팝업을 그릴 최소 후보 수 (1 = 단일 매치도 표시, autocomplete 수준)
: ${SMART_MENU_MAX_MATCHES:=100}       # 이보다 많은 후보는 목록 비표시 (거대 디렉터리와 zsh의 "N개 모두 표시?" 프롬프트 회피)
: ${SMART_MENU_MAX_PREFIX:=64}
: ${SMART_MENU_HISTORY_KEYS:=false}  # true = 줄이 비어 있지 않을 때 ↑/↓ 접두사 히스토리 검색
: ${SMART_MENU_SINGLE_COLUMN:=false} # true = 한 줄에 후보 하나(옵트인: 설명/색/퍼지 매칭 손실). false = zsh 기본 그리드
: ${SMART_MENU_LISTER:=builtin}       # 목록을 누가 그릴지: builtin = 이 플러그인 / fzf-tab = 그리지 않고 외부 선택기로
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

### 단일 열 팝업(옵트인)

`SMART_MENU_SINGLE_COLUMN=true` 는 입력 중 팝업을 zsh 기본 다중 열 그리드 대신
**한 줄에 후보 하나**로 그립니다. **기본값은 꺼짐이며 이는 의도적입니다** — 켜기 전에 읽어
보시기 바랍니다:

- 세로 목록은 후보를 **생성**해야만 그릴 수 있습니다(compsys 자체 후보를 안정적으로 가로챌
  방법이 없습니다: `compadd` 를 함수로 가리면 일부 zsh 에서 후보가 아예 추가되지 않습니다 —
  실측). 따라서 이 모드는 `_main_complete` 를 **우회**하고, 대상 맥락에서 후보 **설명**,
  `list-colors` 색상, 그룹화, `matcher-list` 가 사라집니다. 문서화된 퍼지 매칭은 생성된 후보에
  **적용되지 않습니다**.
- 생성되는 것은 명령 / 함수 / 별칭 / 빌트인, 파일 경로, `cd` 최근 디렉터리뿐입니다. 그 밖의
  맥락(git 하위 명령, ssh 호스트, `--옵션`, `sudo …`)은 여기서 후보가 없어 네이티브 그리드로
  폴백하므로 **입력하는 동안 팝업 모양이 바뀝니다** — "두 번째 목록이 나타났다"로 오해되기
  쉽습니다.
- 터미널 폭보다 긴 후보는 한 줄로 잘립니다(말줄임표 없음).

메커니즘은 산술입니다. 모든 *표시* 문자열을 정확히 `COLUMNS` 폭으로 채우거나 잘라내므로 한 열만
들어갑니다. 입력한 단어는 glob 이 되기 전에 이스케이프되므로 파일 이름의 `[` 가 팝업을 깨뜨리지
않습니다(앞부분의 `~/` 는 이스케이프하지 않아 `~/…` 후보가 그대로 동작합니다).

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

### 목록을 누가 그릴까요? (양자택일)

두 완성 목록 표시기 모두 "그릴 권리"가 있으므로 "목록이 두 개 동시에 뜬다"는 한쪽만 고칠 수 있는
버그가 아닙니다 — 한쪽이 멈춰야 합니다. `SMART_MENU_LISTER` 가 소유자를 정합니다:

| 값 | 결과 |
|---|---|
| `builtin`(기본) | 이전처럼 이 플러그인이 zsh 목록을 구동합니다 |
| `fzf-tab` | 이 플러그인은 **아무것도 그리지 않고**, 화면에는 외부 부동 선택기만 남습니다 |

fzf-tab 을 설치해 주는 것이 아닙니다 — **이** 플러그인이 목록 그리기를 멈춰서, 직접 설치한 다른
목록 표시기만 그리게 합니다. 인라인 회색 제안은 영향받지 않습니다: 넘겨지는 것은 후보 목록뿐입니다.
`fzf-tab` 에서는 Tab 위젯의 `zstyle ':completion:*' menu select` 설정도 중단합니다. zsh 의 선택
메뉴 자체도 같은 화면을 다투는 목록 표시기이기 때문입니다.

```zsh
smart-lister                       # 지금 누가 그리는가
smart-lister builtin | fzf-tab     # 이 shell 에서 전환
```

받아들이는 표기는 다음과 같습니다:

| 이 플러그인을 뜻함 | "넘김"을 뜻함 |
|---|---|
| `builtin` `smart` `internal` `native` `built-in` `on` `yes` `true` `1` | `fzf-tab` `fzf_tab` `fzf` `ftb` `external` `none` `off` `no` `false` `0` |

`off` 는 "**저희** 목록 끔"(즉 넘김)이며 "목록 없음"이 아닙니다 — 그것은 `SMART_MENU=false`
입니다. 알 수 없는 **값**은 `builtin` 으로 되돌아가고(오타로 팝업이 조용히 사라지면 안 됩니다)
"인식할 수 없음"으로 보고합니다. 반면 `smart-lister` 에 준 **인자**가 틀리면 **오류를 내고
0이 아닌 값을 반환**하므로, `smart-lister fzf-tb` 가 전환에 성공한 것처럼 보이지 않습니다.

문제가 생기면 `smart-doctor` 입니다. 현재 주인을 출력하고, 목록이 **로드되지 않은** 피커에
넘겨져 있으면 그것을 명시하며 **그것을 최종 판정으로 삼습니다** — "아무것도 그려지지 않음"이
"목록 두 개"보다 나쁜 상태이기 때문입니다.

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
smart-lister builtin|fzf-tab  # 목록을 누가 그릴지 선택 (fzf-tab = 이 플러그인은 그리지 않음)
smart-recent on|off|status # 최근 디렉터리 후보 + `cd ` 빈 단어 목록
```

## 로컬 설정 스크립트

설치기는 사용자 설정 파일과 이를 관리하는 작은 CLI 를 만들므로, `~/.zshrc` 를 전혀 건드리지 않고도 플러그인을 조정할 수 있습니다. 파일 위치:

```
${SMART_USER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh-smart-complete/settings.zsh}
```

설치 후에는 언제든 `zsc-settings` 를 실행할 수 있습니다（설치기는 이를 `~/.local/bin/zsc-settings` 에 심볼릭 링크하므로, 해당 디렉터리가 `PATH` 에 있는지 확인하거나 스크립트를 전체 경로로 호출하세요）:

| 명령 | 설명 |
| --- | --- |
| `zsc-settings` | 대화형 마법사——설정 항목을 고르고 새 값 입력 |
| `zsc-settings list` | 모든 설정과 현재 적용 값 표시 |
| `zsc-settings get KEY` | 한 설정의 적용 값 출력 |
| `zsc-settings set KEY VALUE` | 값을 검증해 기록 |
| `zsc-settings edit` | 파일을 `$EDITOR` 로 열기 |
| `zsc-settings reset [KEY]` | 덮어쓴 값 하나（또는 전체） 삭제 → 기본값으로 복귀 |
| `zsc-settings path` | 설정 파일 경로 출력 |
| `zsc-settings init` | 주석이 달린 기본값으로 파일 （재）생성 |

값은 그냥 `KEY='VALUE'` 행으로 기록됩니다. 플러그인은 내장 기본값보다 **먼저** 이 파일을 source 하므로, 기록한 값이 기본값을 덮어씁니다. 값을 바꾼 뒤에는 **zsh 를 재시작**（`exec zsh` 등）해 적용하세요. `set` 은 설정 형（bool / int / enum / path）에 맞춰 값을 검증하고 잘못된 입력을 거부합니다. 다른 파일을 쓰려면 zsh 시작 전에 `SMART_USER_CONFIG` 로 그 파일을 가리키면 됩니다.

## 제거

```zsh
rm -rf ~/.zsh-smart-complete
```

## 변경 내역

전체 기록은 [CHANGELOG](./CHANGELOG.ko.md)을 참조하세요. GitHub Release의 릴리스 노트는 이 다국어 CHANGELOG 파일(en / zh-CN / zh-TW / ja / ko)에서 추출됩니다.

## 테스트

```zsh
./tests/run-all.sh            # every suite, one line each
./tests/run-all.sh -v         # ... with full output
./tests/run-all.sh menu       # only suites whose name matches
./tests/run-all.sh --list     # what would run
```

**테스트 요약:** `./tests/run-all.sh` 가 모든 스위트를 실행하고 실측한 파일·어설션 수를 출력합니다. 전부 통과, 0 실패.

`tests/run-all.sh`는 `tests/test-*.zsh`(zsh로 실행)와 `tests/test-*.sh`(bash로 실행)를 **자동 발견**합니다. 테스트 파일을 추가해도 다른 곳을 고칠 필요가 없습니다. CI 잡지는 과거 12개 파일을 손으로 나열했고, 그 옆의 주석이 자백하듯 거기 적지 않은 새 테스트는 조용히 한 번도 실행되지 않았습니다. 각 스위트의 어설션 수를 합산하므로 보고서에 나오는 숫자는 매 실행 실측값입니다.

그중 `tests/test-perf.zsh` 는 동작이 아니라 실측 시간 상한을 단언합니다. 이 프로젝트가 고친 제곱 계산량 버그는 모두 출력은 완전히 정상이었고 증상만 수 초 정지였기 때문입니다.

설치기는 `~/.zshrc` 정리 후 `.zprofile`, `.zshenv`, `conf.d/*.zsh`, `.zshrc.d/*`, `/etc/zsh/zshrc` 같은 **다른 시작 파일**에 `zsh-autocomplete` / `zsh-autosuggestions` 로더 행이 남아 있는지도 **검사**하고, 있으면 정확한 `파일:행번호` 로 **경고**하여 수동 정리를 안내합니다 — 이 파일은 편집하지 않습니다. 자세한 내용은 CHANGELOG의 `[v2.2.5]` 를 보세요.


주요 동작은 tmux 페인 안의 실제 `zsh -i`에 대해 엔드투엔드로 검증되며, 렌더링된
화면을 어설트합니다(49/49 그린). 같은 어설션은 v2.1.6에서는 **24/49**(49개 중 1개는 거기서 도달하지 않습니다 — 해당 섹션은 실패 후 중단됩니다) — 당시
"입력하면 팝업되는 메뉴"는 존재하지 않았고, `SS3` 와 `Alt+→` 인코딩은 죽어 있었으며,
`Tab` 후 `Enter` 는 삼켜지고, 최근 디렉터리는 나열되지 않았고, 목록 표시기 전환도,
단일 열 레이아웃도 없었습니다. 그 24개 통과 중 **일부는 헛돌이**입니다 — "목록을 그리지
않았음"을 검증하는데, v2.1.6 은 목록을 아예 그리지 않습니다. 기준선을 옛 숫자에서 비례해
계산할 수 없는 이유가 바로 이것입니다.
이 하니스는 저장소에 포함됩니다(`tmux` 없으면 자동 스킵):

```zsh
./tests/e2e-tmux.sh                              # 49 어설션
./tests/e2e-tmux.sh /tmp/zsc-v216               # 이전 릴리스와 A/B
```

e2e 는 "버퍼 무결성"도 검증합니다. 한 글자씩 입력한 뒤 프롬프트 줄이
입력 내용과 정확히 일치해야 하고, **실제로 실행된 명령**의 출력으로 교차
검증합니다. 목록을 그릴 때마다 키를 하나 삼키던 조용한 버그는 "화면만 보는"
모든 검사를 통과해 버리기 때문입니다.

방법은 `headless-pty-zle-verify` 스킬에 정리되어 있습니다.

`tests/test-repaint.zsh` 는 tmux 하니스가 **구조적으로 볼 수 없는** 부분을 담당합니다:
zsh 가 키 입력 한 번마다 터미널에 실제로 쓰는 바이트입니다. tmux 는 "개행 + 커서 위로"
쌍을 되돌리기 때문에, 플러그인이 매 키 입력마다 스크롤을 동반한 재그리기를 하더라도 화면
**과** 스크롤백이 **모두** 동일하게 나옵니다. 이 테스트는 `zsh/zpty` 로 실제 `zsh -i` 를
구동하고 원시 바이트 스트림을 읽어, 단 하나의 불변식을 검증합니다: **키 입력 한 번은 한
줄에 머문다** — 개행 없음, 수직 커서 이동 없음, 화면 지우기 없음. 2줄 프롬프트에서의 실측:

| 빌드 | 바이트 | 스크롤을 동반한 개행 |
| --- | --- | --- |
| 매 키 입력마다 재그리기 | 96 | 있음 — 고스트**와** 팝업을 모두 꺼도 32 바이트 (순정 zsh 는 1) |
| 이번 릴리스 | 33 | 없음 — 둘 다 끄면 1 바이트, 순정 zsh 와 정확히 동일 |

구 빌드에서는 실패하고 이 빌드에서는 통과하므로, 이 재그리기를 되살리는 "수정"은
사용자가 아니라 CI 가 먼저 잡습니다. CHANGELOG `[v2.2.10]` 참조.

## 라이선스

MIT — [LICENSE](./LICENSE) 참조.
