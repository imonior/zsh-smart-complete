# 변경 내역

이 프로젝트의 모든 중요한 변경 사항은 이 파일에 기록됩니다.

형식은 [Keep a Changelog](https://keepachangelog.com/)을 따르며, 이 프로젝트는
[의미론적 버전](https://semver.org/lang/ko/)을 준수합니다.

## [v2.2.2] - 2026-09-16

### 수정
- **`Tab` 뒤의 `Enter`가 이제 줄을 실제로 실행**합니다(단순 다시 그리기가 아님).
  이전에는 완성 후 첫 `Enter`가 accept-line 위젯에 삼켜져(완성을 아직 "진행 중"으로
  간주하여 표시만 새로 고침) 완성된 `cd …`를 실행하려면 `Enter`를 **한 번 더** 눌러야
  했습니다. 이제 위젯은 자체 상태를 정리한 뒤 `zle .accept-line`을 직접 호출합니다.
  이는 **이전부터 존재하던 버그**로, v2.2.1에서도 재현됩니다.

### 추가
- **최근 디렉터리 후보**(`lib/engine/recent.zsh`, `SMART_RECENT_PATHS`, 기본 `true`).
  `cd` / `pushd` / `chdir` 인자를 완성할 때 **실제로 이동했던** 디렉터리가 후보로
  제시되며, `cd ` 뒤의 **빈 단어**에서는 즉시 목록으로 표시됩니다——빈 단어를 목록으로
  보여줄 가치가 있는 유일한 상황입니다. 완성기를 `zstyle ':completion:*' completer`
  앞에 삽입하는 방식이라 사용자의 완성 체인과 공존하며, `smart-recent off` /
  `smart-disable` 시 깔끔하게 제거됩니다.
- **읽기 전용.** 데이터는 zsh 자체의 최근 디렉터리 데이터베이스(`cdr`와 `~[1]`가 쓰는
  것과 동일)이며, 플러그인은 **절대 기록하지 않습니다**. `SMART_RECENT_PATHS_MAX`
  (기본 `20`)가 후보 수를 제한하고, `smart-recent status`가 현재 사용 가능한 항목 수를
  보고합니다.
- **`smart-recent on|off|toggle|status`** 런타임 명령.

### 변경
- **퍼지 매칭은 문서화만 하고 직접 구현하지 않습니다.** 라이브 팝업은 사용자 자신의
  완성 시스템을 실행하므로 `zstyle ':completion:*' matcher-list`가 이미 자동으로
  적용됩니다——이 플러그인에는 **퍼지 매칭 코드가 의도적으로 없습니다**. 직접 추가하면
  compsys와 충돌할 뿐입니다. README의 "선택 기능" 절에 설정할 한 줄을 제시합니다.

### 테스트
- `tests/test-recent.zsh`(38개 어설션): `cd` 인자 위치 판정, 데이터베이스 파싱
  (공백 / 따옴표 / XDG 위치 / 오래된 항목), 그리고 **회귀 테스트로 고정**한 사항——
  완성기가 `zstyle ':completion:*' completer`를 통해 연결되며 `$completer` 배열이
  **아님**(그 변수는 zsh에 존재하지 않으며, 이전 코드는 "연결된 것처럼 보였지만" 실제로는
  아무 일도 하지 않았습니다).
- `tests/e2e-tmux.sh`: **8b**(Tab 후 Enter가 실행)와 **9**(`cd `에서 최근 디렉터리 목록,
  Tab으로 전체 경로 완성) 추가. 총 29개 어설션, **v2.1.6에서는 17/29**.

## [v2.2.1] - 2026-09-16

### 수정
- **라이브 팝업이 더 이상 키 입력을 삼키지 않습니다.** 이전에는 `LISTMAX=-1`을 목록 호출
  앞뒤로 스코프 대입해 zsh의 "N개 전부 표시할까요(M줄)?" 프롬프트를 억제했는데, 이것이
  ZLE의 다음 입력 읽기를 손상시킵니다. `git status`를 입력해도 버퍼에는 `gitstatus`만
  들어가고 셸은 **잘못된 명령**을 실행했습니다. 이제 `LISTMAX`는 전혀 건드리지 않고,
  너무 큰 후보 목록을 아예 그리지 않는 방식(`SMART_MENU_MAX_MATCHES`, 기본값을
  "무제한"에서 `100`으로 변경)으로 억제합니다. 짧은 후보 목록과 1200개 항목 디렉터리
  양쪽에서 모두 깨끗했던 유일한 설정입니다.
- `smart-menu status`와 tick 디버그 로그가 "최소값 미만"과 "상한 초과"를 구분합니다.
  이전에는 둘 다 `below min`으로 기록되어 디버깅 방향을 잘못 잡게 했습니다.

### 추가
- **`SMART_SUGGEST_STRATEGY`** (`history` | `history,completion`,
  zsh-autosuggestions와 동일한 이름). `completion`을 추가하면 히스토리에 없는 경로,
  옵션, 하위 명령도 회색 제안으로 표시할 수 있습니다(커서 위치 단어의 "모호하지 않은
  접두사"를 완성 시스템에 질의).
- **이름 있는 재지정 가능 위젯**: `smart-accept-suggestion`, `smart-accept-word`,
  `smart-execute-suggestion`, `smart-suggestion-toggle`.
- **`SMART_MENU_HISTORY_KEYS`** (기본 `false`): `true`이면 줄이 비어 있지 않을 때
  ↑/↓가 접두사 히스토리 검색(zsh-autocomplete의 대표 기능)이 되고, 빈 줄에서는 일반
  히스토리 이동으로 돌아갑니다.

### 테스트
- `tests/e2e-tmux.sh`에 실제 터미널에서의 **버퍼 무결성** 검증을 추가했습니다. 한 글자씩
  입력해 문자가 유실되지 않아야 하고, **실제로 실행된 명령**이 입력한 그대로여야 합니다.
  이전 스위트는 "목록이 그려졌는가"만 확인해서, 팝업이 모든 명령줄을 망가뜨리는 동안에도
  전부 통과했습니다.

## [v2.2.0] - 2026-09-15

이 플러그인이 존재하는 **전체 이유**를 드디어 제공한 릴리스: `zsh-autocomplete` +
`zsh-autosuggestions`의 두 부분을 단일 플러그인 안에서 네이티브로 구현합니다.

### Added
- **입력하면 팝업되는 후보 메뉴** (`lib/engine/menu.zsh`): 버퍼를 편집할 때마다 후보 목록을
  계산하고 그리므로, 완성이 입력 중에 나타납니다 — `Tab` 불필요. 사용자 자신의 compsys 위에
  프라이빗 완성 위젯(`zle -C ... list-choices`)으로 구현하며, 그 completer는 `compstate[nmatches]`를
  읽어 목록을 그릴지 결정하고 `compinit`은 절대 건드리지 않습니다. 마스터 스위치 `SMART_MENU`,
  실행 시 `smart-menu on|off|status`.
- **행 내부 회색 제안과 후보 목록이共存.** 목록 재도화와 `POSTDISPLAY`는 같은 화면 영역을
  다투므로 순서를 고정했습니다: 먼저 회색 글자를 그리고, 그 다음 목록을 실행하고, 이후 재도화하지
  않습니다. 단일 후보(`SMART_MENU_MIN_MATCHES`)는 목록을 버리고 회색 글자에 양보합니다.
- **적응형 스로틀** (`SMART_MENU_SLOW_MS` / `SMART_MENU_COOLDOWN_KEYS`, 기본 끄기): 임계값 이상
  걸리는 목록 가져오기는 쿨다운을 유발하며, **지속적으로** 비싼 완성을 위한 것. 기본 끄기인 이유는,
  실측에서 유일한 spike가 완성 하위 시스템 로드 시의 일회성 ~180ms이며, 이를 줄이면 세션의 첫
  `git <TAB>`에서 팝업을 잃기만 하고 절약은 그 한 번의 180ms뿐이기 때문입니다.
- **`SMART_MENU_DEBUG=/path/to/log`**: 매 tick 결정(게이트 거부 / 쿨다운에 의한 스킵 / 후보 수 /
  측정 밀리초)을 한 줄씩 덧붙입니다. "팝업 안 뜸"은 "후보 하나라 회색 글자에 양보함"과 구분할 수
  없으므로 이 로그가 도움이 됩니다.
- **`Alt+→`로 단어 하나 수락**: 행 내부 제안의 단어 하나를 수락하고(이후 나머지를 다시 제안) 아무
  수락할 것이 없으면 표준 `forward-word`로 폴백합니다.

### Fixed
- **심각 — 새 세션에서 우측 화살표가 안 먹힘**: `ESC [ C`(CSI)만 바인딩했고, `TERM=xterm-256color`의
  `kcuf1`은 `ESC O C`(*애플리케이션 커서 키* 형식)이며, ZLE은 터미널을 그 모드로 전환합니다. 그래서
  그 키는 zsh 기본 `forward-char`로 갔고 제안은 결코 수락되지 않은 채 회색 글자만 보였습니다 — 전형적인
  "회색 글자는 보이는데 화살표는 죽음" 보고. 이제 모든 화살표 인코딩을 바인딩하고, 시퀀스 목록은
  `terminfo`에 CSI/SS3 폴백을 더해 구성합니다.
- **심각 — 같은 터미널에서 `Alt+→`도 죽음**: `Alt`는 문자 그대로 "`ESC`를 보내고 그 다음 화살표"이므로
  다중 인코딩 문제를 물려받습니다. 구버전은 `ESC [ 1 ; 3 C`(xterm)와 `ESC ESC [ C`만 바인딩했고,
  애플리케이션 커서 키 모드 터미널이 보내는 `ESC ESC O C`는 바인딩되지 않아 리터럴 `^[`를 버퍼에
  떨어뜨렸습니다. `Alt` 형식은 이제 "각 화살표 인코딩에 `ESC`를 접두"하여 **파생**하므로 둘이 다시
  어긋나지 않습니다.
- **바인딩 캡처가 원시 바이트 시퀀스를 오파싱**: `_smart_evt_binding`(`lib/event/zle.zsh`)과
  `_smart_current_binding`(`lib/engine/native.zsh`)은 조회한 시퀀스를 텍스트 매칭으로 벗기려 했으나,
  `bindkey`는 키를 항상 `^X` 기호법으로 에코하므로 원시 바이트 시퀀스(예: terminfo `kcuf1`)에서는
  매칭이 실패하고 *키 텍스트*가 위젯 이름으로 저장되었습니다. 저장된 원본이 오염되어 언바인드 시 키가
  복원되지 않았습니다. 두 파서 모두 이제 `bindkey` 출력의 마지막 필드를 취합니다.
- **루프 내 `local`이 stdout으로 새나감**(`lib/event/zle.zsh`): zsh 5.9는 `local` 선언을 두 번째
  이후 실행할 때 `var='<옛값>'`을 출력하며, 이는 1회 초과 반복되는 루프 안에 쓴 `local`에서 발생합니다.
  그 출력은 ZLE 위젯 경로에서 그대로 명령행에 닿습니다. 모든 루프 변수를 함수 맨 위에서 한 번에 선언하도록
  했고, `tests/test-zle.zsh`가 bind/unbind 사이클의 무음을 어설트합니다.
- **`zmodload -F` 기능 접두사**: `EPOCHREALTIME`과 `terminfo`는 *파라미터*이므로 `p:EPOCHREALTIME` /
  `p:terminfo`로 요청해야 합니다. 거부된 `b:` 요청으로 둘 다 미정의인 채로 남아 스로틀과 terminfo
  유래 화살표 시퀀스가 조용히 비활성화되었습니다. 회귀 테스트 추가.
- **연관 배열 따옴표 첨자**: `assoc["km|seq"]=x`는 따옴표를 키 이름의 일부로 저장하므로 `assoc[km|seq]`로
  도달할 수 없습니다. 키는 이제 변수로 조립하고 인용 없는 첨자로 색인합니다(`lib/state.zsh`가 이미
  지키던 규칙과 동일).
- **설치기**: *왜* `zsh-autocomplete` / `zsh-autosuggestions`를 제거하는지(두 동작 모두 이제 네이티브)
  설명하며, 더 이상 조용히 삭제하지 않습니다.

## [v2.1.6] - 2026-09-15

### Fixed
- **심각 — 인쇄 가능 ASCII 입력이 삼킴**: `_smart_evt_binding`이 `bindkey -R "^@-^_"` 범위 쿼리에서
  의사 위젯 `undefined-key`를 캡처해 인쇄 가능 키를 거기에 디스패치했으므로, `zle undefined-key`(무효
  동작)가 모든 ASCII 키입력을 먹었습니다. CJK/UTF-8(바이트 >= 0x80, 재바인드 범위 밖)은 진짜
  `self-insert`로 계속 삽입되어 "중국어는 되고 영어는 안 됨". 캡처는 이제 `undefined-key`를 미바인드로
  정규화해 `self-insert`를 쓰고, `_smart_evt_dispatch`도 방어하며, `_smart_current_binding`(native.zsh)
  역시 강화. `tests/test-zle.zsh`에 회귀 테스트 추가.
- **키 캡처 강화**: self-insert 원본 위젯은 이제 범위 탐색이 아니라 하드코딩합니다(범위 쿼리는 우리 바인드
  전에는 `undefined-key`, 후에는 우리 wrapper를 반환하며 어느 쪽도 쓸 수 있는 원본이 아님). 캡처는 전용
  플래그 `_SMART_EVT_CAPTURED`로 방어하며, 단일 `ORIG_*` 변수의 내용이 아니라 하므로, 오래되거나 수동
  설정한 `_SMART_EVT_ORIG_SELF_*`가 전체 캡처를 건너뛰는 일(그러면 네이티브 Tab 바인드와 다른 모든 원본도
  조용히 사라짐)이 없어졌습니다. 캡처 탐색은 또한 어떤 `_smart_*` / `smart-*` 위젯 기록도 거부하여, 재캡처가
  우리 wrapper로 다시 디스패치되지 않습니다.
- **설치기 — 관리 블록 마커가 쓰여지지 않음**: `build_zsc_integration`이 bash 스크립트 안에서 `print -r --`
  (zsh 내장)을 써서 호출이 조용히 실패했고, `# >>> zsh-smart-complete integration (managed) >>>` / `# <<< ... <<<`
  마커 줄이 빠졌습니다. BEGIN 마커가 없으면 `_upsert_zsc_block`이 맞을 수 없어 재설치마다 중복 블록을
  덧붙였습니다. 이제 `printf '%s\n'` 사용.

### Added
- **선택적 `zsh-vi-mode`(opt-in, 기본 NO)**: vi 키바인드는 확실히 유용하나, 이 플러그인은 키맵 전체를
  소유하고 매 라인 초기화에서 ZLE을 재초기화하므로 다른 플러그인 바인드를 부수는 전형적 원인입니다 — 그래서
  암묵적 설치는 절대 없습니다. 사용자가 선택하면 설치기는 그것을 클론하고, 우리 위젯을 *이전*에 로드하며
  `zvm_after_init` / `zvm_after_lazy_keybindings`로 재적용하는 블록을 씁니다.
- **설치기가 흐름 중 fast-syntax-highlighting 설치**(`_ensure_zinit_plugin
  zdharma-continuum/fast-syntax-highlighting`), 풀 콤보와 플러그인 양 경로 모두, Zinit 첫 시작 자동
  클론에 더 이상 의존하지 않습니다.

### Changed
- **설치기 .zshrc 전략**: 완전 권장 `.zshrc` 템플릿은 이번에 풀 스택을 (재)설치한 경우(Phase 0/5 콤보)에만
  권장. 플러그인만 설치는 이제 마커 구분 `zsh-smart-complete` 블록만 관리(멱등 upsert, 파일 전체를 덮어쓰지
  않음).

## [v2.1.5] - 2026-09-15

### Fixed
- **설치기 — p10k/OMZ 제거기**: `_remove_p10k` / `_remove_omz`는 이제 Zinit 클론 플러그인 dir
  (`$ZINIT_PLUGINS_DIR` 아래 `romkatzen---powerlevel10k`, `OMZ::ohmyzsh---ohmyzsh`)도 삭제하므로,
  비 p10k/OMZ 콤보를 고르면 다음 시작에 다시 로드되는 낡은 잔재를 완전히 지웁니다. `.bak.*` 산물은
  계단식 백업을 피해 직접 삭제.
- **설치기 — `.zwc` 바이트코드**: 플러그인 갱신 경로(`git reset --hard`)는 이제 Zinit 컴파일 `*.zwc`
  캐시도 제거하므로 엔진 수정이 갱신 후 실제로 효력(이전엔 낡은 컴파일 코드가 로드됨).
- **엔진 — 전역 누수**: `lib/engine/suggest.zsh`의 `cmd_cwd` / `cmd_host` / `cmd_exit`는 이제 `local`
  선언(이전엔 매 키입력마다 전역으로 새어나감).
- **엔진 — 히스토리 상한**: `_SMART_CMDS`는 이제 `SMART_SUGGEST_HISTORY_LIMIT`(기본 20000)로 제한.
  `SMART_HISTORY_REBUILD_EVERY=0`으로 주기 재구성을 끄면 가장 오래된 항목을 버리고 bucket/assoc 슬롯을
  동기 유지.

## [v2.1.4] - 2026-09-12

### Fixed
- fzf 설치가 조용히 건너뛰어짐(비대화). 설치 진행이 두 번 표시(Phase 0/5 그리고 Phase 1-4). `RAN_COMBO`
  가드 추가하고 fzf 프롬프트를 대화식으로.

## [v2.1.3] - 2026-09-11

### Fixed
- 모든 y/N 프롬프트에서 `read: -: invalid option` 크래시 — `IFS=$'\n\t'`가 `read $_args`를 망가뜨림.
  `read "$@"`로 변경.

## [v2.1.2] - 2026-09-10

### Fixed
- 설치기 프롬프트는 이제 사용자가 각 단계를 확인할 때까지 블록. 충돌 플러그인 `.bak.*` 계단식 수정(주 dir은
  한 번만 백업). 낡은 플러그인은 이제 `git fetch --depth 1` + `git reset --hard`로 실제 갱신.

## [v2.1.1] - 2026-09-09

### Added
- **zsh 재설치 프롬프트**: zsh가 이미 설치돼 있으면 brew(macOS)나 apt(Debian/Ubuntu)로 재설치/업그레이드
  권유.
- **fast-syntax-highlighting**: `.zshrc` 템플릿의 `zinit light
  zdharma-continuum/fast-syntax-highlighting`으로 로드(Zinit는 시작 시 자동 클론). install.sh가 직접 관리
  않음.
- **i18n 메시지**: zh-CN, zh-TW, ja, ko, en에 `prompt.zsh_reinstall` 추가.

### Changed
- **Phase 0**: 풀 콤보 설치에 zsh 재설치 로직 포함. fast-syntax-highlighting은 Zinit 경유 `.zshrc` 템플릿
  로드.
- **Phase 1-3**: starship/atuin/zinit 프롬프트의 `SKIP_DEPS` 가드 복원.

### Fixed
- zsh 재설치 프롬프트는 올바른 brew/apt 폴백 로직 사용.

## [v2.1.0] - 2026-09-08

### Added
- **Phase 0/5**: 완전 권장 콤보 설치(zsh + fzf + starship + atuin + zinit + zsh-smart-complete).
- **대화식 백업 정리**: 충돌 플러그인 잔재(`.cache/p10k-*`, `.cache/zsh*`, `.local/state/zsh-autocomplete`
  등) 정리 권유.
- **fzf 자동 설치**: 패키지 관리자로 못 구하면 GitHub에서 클론.

### Changed
- `SKIP_DEPS!=1`이고 `NONINTERACTIVE!=1`일 때 설치기는 이제 먼저 Phase 0 실행. Phase 0 건너뛰면 Phase 1-3이
  폴백.

## [v2.0.6] - 2026-08-26

### Fixed
- 릴리스 워크플로: tar/zip 전에 파일 stage하여 'file changed' 경합 회피.

## [v2.0.5] - 2026-08-26

### Fixed
- `mirror.chosen` 메시지의 잘못된 변수 치환.
- 낡은 `.bak.*` 잔재 정리.

## [v2.0.3] - 2026-08-26

### Fixed
- i18n: 남은 모든 중국어 상태 메시지 번역.
- SSH 입력 문제 수정.

## [v2.0.2] - 2026-08-26

### Fixed
- i18n: 미러 선택 메뉴 완전 국제화.

## [v2.0.1] - 2026-08-26

### Fixed
- 설치기 문제 3건 해결: i18n 콤보 메뉴, OMZ/p10k 기본 yes, starship.toml 이스케이프.

## [v2.0.0] - 2026-08-25

### Added
- 엔진과 설치기 재작업.
- O(bucket) 접두사 인덱스.
- de-subShell 스코어링.
- 실시간 증분 인덱스.
- Zsh 감지.
- OMZ/p10k 콤보 셀렉터.
- Entware 설치기.
- ZLE 행 편집기를 어지럽히던 매 키입력 stdout 누수 중단.

## 이전 릴리스

```
v0.1.0  ZLE 프론트엔드, 히스토리 인덱스, 제안 엔진
   │
v0.1.3  결정적 순위(감쇠 + 빈도 + CWD 부스트)
   │
v0.2.0  Atuin SQLite 백엔드(host / exit / CWD 인식 순위)
   │
v1.0.0  GA — 안정 공개 API, CI/CD, 자동 릴리스
   │
v2.0.0  엔진과 설치기 재작업 — O(bucket) 접두사 인덱스, de-subShell
        스코어링, 실시간 증분 인덱스, Zsh 감지, OMZ/p10k 콤보
        셀렉터, Entware 설치기
   │
v2.1.0  Phase 0 풀 콤보 설치(zsh + fzf + starship + atuin + zinit +
        zsh-smart-complete), 대화식 백업 정리
   │
v2.1.6  인쇄 가능 ASCII 입력 수정(undefined-key), 캡처 강화,
        fast-syntax-highlighting, 콤보 인식 .zshrc, opt-in zsh-vi-mode
   │
v0.5.x  smart-shell-engine(Rust / Go, IPC 경유)(미래, opt-in)
   │
v2.0    Smart Shell — 완전한 독립 셸(미래)
```
