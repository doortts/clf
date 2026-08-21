# clf

Claude Code 데스크톱 앱 사용자용 메뉴바 도구

![메뉴바](docs/images/menubar.png)

## 주요 기능
- Claude code 여러 계정을 사용량, 리셋시간등을 메뉴바에서 볼수 있습니다.
- 한 계정에서 작업하던 세션을 다른 계정으로 이전하거나 두 계정에서 동시에 쓸수 있게 해줍니다.
- 여러개의 Claude code desktop 앱 창을 실행할 수 있습니다.
  - 팁. ChatGPT(구. Codex) Desktop 앱은 이미 GUI 멀티 윈도우 기능을 지원합니다.
- * 추론 요청을 보내지 않으므로 조회에 토큰을 쓰지 않습니다.

## 한계 사항
- macOS 전용앱니다.
- Claude code cli 설치되어 있어야 합니다.


## 세션 작업 다루기

- 팝오버 아래 `작업이전/자동재개` 를 누르면 창이 뜹니다.

- **작업 이전.** 
  - 한도에 걸려 멈춘 대화를 다른 계정 창으로 옮길수 있습니다. 
  - 참고: ([13 문서](docs/design/13-multi-instance.md)).

- **양쪽에 두기.** 
  - 옮기는 대신 레코드를 두 계정에 함께 두는 기능입니다.
  - 참고: ([14 세션 공유](docs/design/14-shared-session.md)).

## clfctl

- 추가 cli 도구
- 앱 없이 같은 데이터를 보는 도구. 
- 개발용으로 사용합니다

```bash
./scripts/install-clfctl.sh
```

```
clfctl desktop usage              계정별 잔여
clfctl desktop usage --json       기계가 읽을 형태로
clfctl desktop orgs               아는 계정과 표시 여부
clfctl desktop hide <이름|uuid>    목록에서 뺀다
clfctl desktop show <이름|uuid>    다시 보이게 한다
clfctl desktop order <이름...>     표시 순서
clfctl desktop bar <window|chosen> 막대에 그릴 범위
```

메뉴바 숫자와 `clfctl desktop usage` 는 항상 같은 값을 낸다. `clfctl` 이
소스보다 낡았으면 실행할 때 알려준다.

---

## AI 와 함께 일하기

### 코드를 읽힐 때

1. `CLAUDE.md`: 문자 규칙과 커밋 규칙
2. [00 범위](docs/design/00-scope.md): **데스크톱 트랙과 터미널 트랙이 갈린다.**
   01 부터 07 까지는 방향이 바뀌기 전에 쓴 터미널 트랙 문서입니다. 이걸 먼저
   갈라 주지 않으면 제품에 없는 프록시 코드를 고치기 시작한다
3. 기능 문서 -> `Sources/ClfDesktop/<기능>.swift` -> 같은 이름의 테스트

판단은 전부 `ClfDesktop` 에 있고 `ClfApp` 에는 뷰와 상태 하나뿐입니다. 잔여 계산,
이름 줄이기, 남은 시간 표기가 모두 순수 함수라 **테스트가 명세다.** 동작이
궁금하면 `Tests/ClfDesktopTests` 의 테스트 이름부터 읽습니다..

"왜 이렇게 했나" 는 코드 주석과 설계 문서에 있고 대개 문서 번호를 달아 두었습니다.
주석에 `docs/design/...` 이 보이면 그 문서가 근거입니다.

| 타겟 | 담는 것 | 안 담는 것 |
|---|---|---|
| `ClfCore` | 순수 판정(계정 선택, 응답 분류, SSE, 헤더). **의존성 0** | 파일, 네트워크 |
| `ClfStore` | 우리 파일과 키체인 읽기, 원자적 쓰기 | 데스크톱 앱의 것 |
| `ClfDesktop` | 데스크톱 앱 상태 읽기와 앱의 모든 판단 | 뷰 |
| `ClfApp` | SwiftUI 뷰와 `UsageModel` | 판단 |
| `ClfProxy` | 터미널 트랙 프록시(NIO) | 제품 경로 |
| `clfctl` | 위를 손으로 돌려보는 CLI | 판단 |

물어볼 때 문서 절 번호까지 집어 주면 헛짚지 않는다.

```
docs/design/16-auto-resume.md 3절을 읽고, 보류 사유를 화면에 남기는 코드가
AutoResumeDriver 와 ResumeTab 중 어디에 있는지 찾아. 고치기 전에 관련 테스트
이름을 먼저 보여줘.
```

### PR 을 보낼 때

- `swift test` 가 통과해야 한다. **새 판단에는 테스트를 먼저 쓴다.** 뷰에는
  판단을 두지 않는다. 뷰는 테스트할 수 없기 때문이다
- 커밋은 Conventional Commits, 스코프는 모듈이나 디렉토리 이름
  (`app`, `desktop`, `core`, `scripts`, `docs`)
- 커밋 하나에 한 가지. 리팩터링과 기능을 같은 커밋에 섞지 않는다
- **작성 도구를 밝히는 trailer 를 넣지 않는다.** `Co-Authored-By` 도 해당한다
- 문서와 주석에는 타이핑할 수 있는 문자만 쓴다. 검사 명령이 `CLAUDE.md` 에 있다
- 화면을 바꾸면 시안 HTML 을 `docs/design/` 에 두고 커밋 메시지에서 가리킨다.
  기존 시안이 그 형식의 견본이다

설계가 바뀌는 변경이면 코드보다 문서가 먼저다. 문서를 고치게 하고, 그 문서를
근거로 코드를 짜게 한다. 순서를 뒤집으면 근거 없는 코드가 남는다.

---

## 개발

```bash
swift test
```

```
./dev.sh                    디버그 빌드로 이 터미널에 붙여 띄운다
./dev.sh desktop usage      앱 대신 clfctl 을 부른다
./scripts/install-app.sh    ~/Applications 에 설치
./scripts/make-app.sh       .app 번들만 만든다
```

# 릴리즈
```bash
./scripts/release.sh v0.4.0 --publish
```

---

## 문서

[docs/design/00-scope.md](docs/design/00-scope.md) 를 먼저 읽습니다.