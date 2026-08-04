# 01. 아키텍처

> 1절과 2절은 방향이 바뀐 뒤 갱신했다. 3절과 4절은 **터미널 트랙**이다.
> 전체 범위는 [00 범위](00-scope.md) 를 본다.

시스템 경계, 모듈 분해, 동시성 모델, 프로세스 수명.

---

## 0. 설계 원칙

**단순하고 그냥 잘 동작하는 것**이 목표다. 기능 개수가 아니라 손댈 일이 없는 상태를 만든다.

| 원칙 | 실제로 뜻하는 것 |
|---|---|
| 기본값으로 동작한다 | 설치하고 조직 등록하면 끝. 임계값이니 예산이니 묻지 않는다 |
| 결정을 미루지 않는다 | 우리가 정할 수 있는 것은 우리가 정하고 설정에 내놓지 않는다 |
| 손해를 기본값으로 만들지 않는다 | 프록시 때문에 꺼지는 기능은 **우리가 되살린다**. 4절 |
| 조용하다 | 남의 작업을 끊지 않는다. 그래서 자동 전환을 접었다. [09 문서](09-desktop-org-switch.md) |
| 화면이 적다 | 팝오버 하나. 설정은 그 안에서 접었다 편다 |
| 남의 것을 안 건드린다 | 데스크톱 앱의 파일은 **읽기만** 한다 |

이 원칙이 실제로 잘라낸 것들.

- API 비용 집계, 활동량 통계, 세션 대시보드 -> 넣지 않는다. 한도 관리가 전부다
- grace 예산, 요청 본문 상한, 쿨다운 길이 -> 상수로 고정. 설정에 내놓지 않는다
- 선제 전환 임계값 -> 켜기/끄기만 노출. 숫자는 고정값으로 시작한다
- 메뉴바 표시 -> 막대는 활성 조직만이 기본. 전부 보고 싶을 때만 바꾼다

---

## 1. 시스템 경계

clf 이 소유하는 것과 소유하지 않는 것을 먼저 못박는다. 대상이 둘이고 방식이
다르다.

### 데스크톱 트랙 (지금 제품)

```
  [Claude Code 데스크톱 앱]                   [계정별 창]
        |                    ^                    ^
        |  config.json,      |  세션 레코드       |  우리가 띄운다
        |  Cookies           |  (SessionMirror,   |  CLAUDE_USER_DATA_DIR
        |  읽기만 한다        |   SessionHandoff)  |  =~/.claude-alt-<이름>
        v                    |                    |
  +----------------------------------------------------+
  |  clf.app  (LSUIElement)                           |
  |    MenuBarExtra + 팝오버                           |
  |    DesktopReader (조직별 토큰 해독)                |
  |    RefreshPacer, ReadGate (갱신 주기와 문)         |
  |    AltLauncher (계정별 창), Notifier (알림)        |
  +----------------------------------------------------+
        |
        |  GET /api/oauth/usage        <- 추론 요청이 아니다
        v
  [api.anthropic.com]
```

`config.json` 과 `Cookies` 는 읽기만 한다. **쓰는 것은 세션 레코드뿐이다.**
420바이트짜리 포인터 파일이고 대화 내용에는 손대지 않는다.
[13 문서](13-multi-instance.md) 10절과 11절.

앱의 트래픽이 우리를 거치지 않는다. 우리는 앱이 남긴 자격증명으로 **따로**
사용량을 물어볼 뿐이다. 앱이 죽어도 우리가 죽어도 상대는 멀쩡하다.

데스크톱 앱을 프록시로 태우려 했으나 막혔다. [00 범위](00-scope.md) 2절.

### 터미널 트랙 (코드는 있고 제품은 아니다)

```
  [터미널 claude]                <- settings.json 의 env 블록 한 줄만 건드린다
        |
        |  HTTP (127.0.0.1:고정포트)
        v
  +---------------------------------------+
  |  Router (계정 선택, 쿨다운)           |
  |  ProxyServer (peek, 분류, 릴레이)     |
  |  Store (Keychain, 설정, 로그)         |
  +---------------------------------------+
        |
        |  HTTPS
        v
  [api.anthropic.com]  또는 계정별 base_url
```

clf 은 **대화를 소유하지 않는다.** Messages API 는 stateless 이고 전체 이력은 매
요청 body 에 담겨 온다. 여기서 하는 일은 요청 하나에 어떤 인증 헤더를 붙일지
정하는 것뿐이다.

### 소유하지 않기로 한 것

| 항목 | 이유 |
|---|---|
| 대화 실행 UI | Claude Code 의 일 |
| 데스크톱 앱의 파일 | 읽는다. **쓰지 않는다.** 조직 전환도 안 한다 |
| 토큰 갱신 | 데스크톱 앱이 하게 두고 만료되면 그 사실만 말한다 |
| `~/.claude/` 의 나머지 전부 | 터미널 트랙에서 `settings.json` 의 `env` 블록만 |
| Agent View 백그라운드 워커 (MITM) | 범위 밖 |

---

## 2. 모듈 분해

Swift Package Manager 타겟 여섯. **의존은 한 방향으로만 흐른다.**

```
ClfApp        (SwiftUI, MenuBarExtra, MainActor)     clfctl  (검증 도구)
   |                                                     |
   +--> ClfDesktop  (남의 앱 읽기, 사용량, 설정)  <-----+
   |       |                                             |
   |       |            ClfProxy  (NIO, 터미널 트랙) <--+
   |       |               |
   +-------+---------------+--> ClfStore   (Keychain, 설정 파일, JSONL)
   |       |               |       |
   +-------+---------------+-------+--> ClfCore  (순수 도메인. I/O 없음)
```

`ClfDesktop` 과 `ClfProxy` 는 서로 모른다. 트랙이 다르다.

| 타겟 | 담는 것 | 담지 않는 것 |
|---|---|---|
| **ClfCore** | HeaderBag, 헤더 변환, 응답 분류, reset epoch 계산, SSE 경계 스캐너/파서, 계정 선택 알고리즘, 쿨다운 산술 | 네트워크, 파일, 시계, 로그 |
| **ClfStore** | Keychain 토큰, 계정/우선순위 영속화, 모델 쿨다운 캐시, usage/audit JSONL, `~/.claude/settings.json` 관리 | 라우팅 판단 |
| **ClfDesktop** | safe storage 해독, 토큰 캐시 파싱, Usage API, 표시 문자열, 갱신 주기, 설정, 계정별 창 관리, 세션 레코드 옮기기 | 화면 |
| **ClfProxy** | 로컬 HTTP 서버, 업스트림 실행기, peek/릴레이 펌프, Router actor | 헤더/분류 규칙 (Core 호출) |
| **ClfApp** | MenuBarExtra, 팝오버, 설정 화면, 넘기기 창, 알림 보내기, 로그인 항목 등록 | **판단.** 전부 ClfDesktop 에 있다 |

**`ClfDesktop` 의 비목표에서 "남의 파일 쓰기" 를 지웠다.** 처음에는 읽기만
했지만 [13 문서](13-multi-instance.md) 10절과 11절이 세션 레코드를 옮기면서
데스크톱 앱의 데이터 디렉토리에 쓴다. 사용량 읽기 경로는 여전히 읽기 전용이고,
쓰는 자리는 `SessionMirror` 와 `SessionHandoff` 둘뿐이다.

`ClfApp` 에 판단을 두지 않는 이유는 뷰를 테스트할 수 없기 때문이다. 잔여를
몇 퍼센트로 쓸지, 이름을 어떻게 줄일지, 리셋까지 몇 시간인지가 전부 순수
함수라 `ClfDesktopTests` 가 잠근다. [11 문서](11-menubar-app.md) 2절.

### ClfCore 를 순수하게 유지하는 이유

claulay 가 가장 잘한 설계다. `swap.ts` 주석의 표현을 빌리면 "purity posture: 루프는
주입된 의존성만 만지고 모든 I/O 는 deps 객체를 통과하므로 단위 테스트가 오프라인에서
돈다".

그 결과 claulay 는 소스와 맞먹는 분량의 테스트를 네트워크 없이 돌린다. 우리가 옮기려는
지식([포팅 문서](../porting/README.md))이 전부 그 테스트 안에 있으므로, **같은 경계를
유지해야 그 테스트를 그대로 옮길 수 있다.**

규칙:

- ClfCore 의 모든 함수는 입력 -> 출력 순수 함수이거나, 값 타입 상태를 받아 새 값을 낸다
- 시계는 `now: Date` 파라미터로 받는다. `Date()` 를 내부에서 부르지 않는다
- 난수, 파일, 소켓 금지

---

## 3. 동시성 모델

Swift 6 strict concurrency 를 켠다. 격리 도메인은 셋뿐이다.

```
  MainActor                    actor Router                 Task (요청당 1개)
  ---------                    ------------                 -----------------
  SwiftUI 뷰                   런타임 상태의 단일 소유자     ProxyServer 핸들러
  ViewModel                      - 계정별 상태               UpstreamExecutor
       ^                         - 쿨다운 맵                 peek / 릴레이 펌프
       |                         - 활성 계정                        |
       |  AsyncStream            - ratelimit 스냅샷                 |
       |  <RouterSnapshot>              ^                           |
       +---------------------------------+---------------------------+
                                    값 타입 스냅샷만 오간다
```

### 핵심 규칙: Router actor 는 업스트림 I/O 를 await 하지 않는다

```swift
// 나쁨: 네트워크 지연 동안 actor 가 잠긴다
await router.attemptAndApply(request)     // 내부에서 업스트림 await

// 좋음: 스냅샷 -> I/O -> 결과 적용
let selection = await router.select(model: model, excluding: tried)
let attempt   = try await executor.execute(selection, body)   // actor 밖
await router.apply(outcome: classify(attempt), to: selection.accountID)
```

claulay 의 `Runtime.snapshot()` 이 방어적 깊은 복사를 반환하는 것과 같은 이유다.
동시 요청이 여럿이므로 (Claude Code 본체 + agent teams + 백그라운드 세션) actor 를
네트워크 왕복 동안 붙잡으면 전체가 직렬화된다.

### 동시 선택은 배타적이지 않다

여러 요청이 동시에 같은 계정을 고르고 모두 429 를 맞을 수 있다. 이는 허용한다.

- 쿨다운 적용은 멱등이다. 나중 429 의 `reset_epoch` 가 최신 정보이므로 덮어쓴다
- 요청별로 이미 시도한 계정 집합(`tried`)을 들고 있어 같은 요청 안에서는 재선택하지 않는다
- 풀이 순간 비면 grace 예산 안에서 대기 후 재훑기 ([02 문서](../porting/02-response-classification.md) 4절)

### NIO 이벤트루프와 Swift concurrency 의 접점

로컬 서버는 NIO 채널 파이프라인으로 받고, 요청 핸들러는 `Task` 로 넘긴다. 업스트림은
AsyncHTTPClient 의 `AsyncSequence` 를 쓴다. 릴레이 루프에서 클라이언트 쓰기를
`await` 하는 것이 backpressure 그 자체다 ([03 문서](../porting/03-sse-streaming.md) 7절).

---

## 4. 프로세스 수명과 settings.json 소유권

**이 절이 claulay 대비 가장 큰 신규 설계 부담이다.** claulay 는 invocation 마다 프록시가
뜨고 죽었으므로 "프록시가 없는 상태" 자체가 정상이었다. clf 은 아니다.

### 정정: 이 방법은 터미널 CLI 에만 통한다

처음에는 데스크톱 앱도 이 방법으로 돌릴 수 있다고 적었다. **틀렸다.** 8단계에서
실측으로 확인했다. 데스크톱 앱은 자식 프로세스 환경에 `ANTHROPIC_BASE_URL` 을
직접 꽂고, 그 이름을 관리 대상 변수로 잠가 두었다. 프로세스 환경에 이미 있는
값을 `settings.json` 이 이길 수 없다.

이 절의 나머지 내용은 **터미널 `claude`** 를 대상으로 그대로 유효하다.
근거와 관측은 [08 검증](08-verification.md) 7-4절.

### 문제

`~/.claude/settings.json` 의 `env.ANTHROPIC_BASE_URL` 이 우리 포트를 가리키는데 앱이
떠 있지 않으면, Claude Code 는 매 요청 connection refused 를 맞는다. 사용자 입장에서는
Claude Code 가 통째로 고장 난 것으로 보인다.

### 결정

**설정 주입과 프로세스 수명을 같은 생명주기로 묶는다.**

| 시점 | 동작 |
|---|---|
| 최초 활성화 | 포트 바인딩 성공 **후에** settings.json 에 주입. 실패하면 주입하지 않는다 |
| 정상 종료 | settings.json 에서 우리 키를 제거하고 종료. 종료 후 Claude Code 는 직접 호출로 복귀 |
| 로그인 시 자동 실행 | `SMAppService.mainApp.register()` 로 로그인 항목 등록 (사용자 선택) |
| 비정상 종료 후 재실행 | 시작 시 settings.json 을 검사해 우리 값이 stale 하면 복구 |
| 사용자가 비활성화 토글 | 프록시는 계속 돌지만 settings.json 에서 제거. 디버깅용 escape hatch |

**정상 종료 시 제거**가 계약의 핵심이다. 사용자가 앱을 끄면 Claude Code 가 고장 나는 것이
아니라 그냥 원래대로 돌아가야 한다.

### settings.json 편집 규칙

```swift
protocol ClaudeSettingsManaging {
    func readManagedBaseURL() throws -> URL?
    func install(baseURL: URL, enableToolSearch: Bool, force: Bool) throws
    func uninstall() throws
}
```

- **read-modify-write.** 모르는 키는 전부 보존한다. 사용자의 `hooks`, `statusLine`,
  `permissions`, `model` 을 절대 잃지 않는다
- 최초 쓰기 전에 `settings.json.clf.bak` 로 백업
- 우리가 만지는 키는 `env.ANTHROPIC_BASE_URL` 과 `env.ENABLE_TOOL_SEARCH` 둘뿐
- 이미 다른 값이 들어 있으면 거부하고 사용자에게 알린다. `force` 로만 덮어쓴다
- `CLAUDE_CONFIG_DIR` 환경변수가 있으면 그 경로를 쓴다

### 프록시가 끄는 기능은 우리가 되살린다

`ANTHROPIC_BASE_URL` 이 first-party 호스트가 아니면 Claude Code 가 **MCP 도구 검색을
스스로 끈다.** 프록시가 `tool_reference` 블록을 제대로 전달하는지 알 수 없기 때문이다.

clf 은 응답을 바이트 그대로 릴레이하므로 그 블록을 온전히 전달한다. 따라서
**`env.ENABLE_TOOL_SEARCH = "true"` 를 `ANTHROPIC_BASE_URL` 과 함께 항상 쓴다.**

옵션이 아니라 기본이다. 사용자가 도구 검색이 꺼진 것을 눈치채고 설정을 뒤지게 만들면
그 시점에 이미 진 것이다. 설정 창에는 문제 해결용 토글로만 남기고 기본값은 켬이다.

원격 제어(Remote Control)는 되살릴 방법이 없다. `api.anthropic.com` 이 아니면 동작하지
않는 것이 클라이언트 정책이라 우리 쪽에서 할 수 있는 일이 없다. 이건 README 에 대가로
적어둔다.

### 포트

```
설정된 고정 포트 (기본 51710) 로 바인딩 시도
  |
  +-- 성공          -> settings.json 주입
  +-- 이미 사용 중  -> 우리 이전 인스턴스인지 확인
  |                     |
  |                     +-- 맞음   -> 단일 인스턴스 가드. 기존 앱을 전면으로 내고 종료
  |                     +-- 아님   -> 다음 빈 포트로 폴백 + settings.json 갱신 + 사용자 고지
```

바인딩 자체가 단일 인스턴스 락 역할을 한다.

### Agent View 백그라운드 워커

claulay 는 이 문제를 MITM TLS 로 풀었다 (`connect-proxy.ts`, `mitm-ca.ts`, opt-in,
기본 off). 일부 백그라운드 워커가 `ANTHROPIC_BASE_URL` 을 무시하고 `api.anthropic.com`
으로 직접 HTTPS 를 호출하기 때문이다.

**1차 범위에서 제외한다.** 로컬 CA 발급과 신뢰 저장소 조작은 메뉴바 앱에서 사용자 동의
비용이 크고, 이 기능이 필요한 사용자가 부분집합이다. 나중에 명시적 opt-in 으로 붙인다.

---

## 5. 테스트 이음새

주입 지점을 미리 정해 둔다. 전부 프로토콜이며 프로덕션 구현과 테스트 페이크가 짝을 이룬다.

```swift
protocol Clock            { var now: Date { get } }
protocol UpstreamExecuting { func execute(_ req: UpstreamRequest) async throws -> UpstreamAttempt }
protocol TokenStoring      { func token(for: AccountID) throws -> String
                             func store(_ token: String, for: AccountID) throws
                             func remove(_ id: AccountID) throws }
protocol EventSinking      { func append(_ event: RoutingEvent) }
protocol ClaudeSettingsManaging { /* 4절 */ }
```

이렇게 하면:

- 스왑 루프 테스트가 소켓 없이 돈다. 가짜 executor 에 429 시퀀스를 주고 선택 순서를 검증
- 쿨다운 산술 테스트가 `Clock` 을 고정해 결정적으로 돈다
- Keychain 접근 없이 계정 CRUD 테스트가 돈다

claulay 의 `interceptor.test.ts` / `headers.test.ts` / `stream-peek.test.ts` 케이스 목록이
그대로 ClfCore 테스트가 된다 ([포팅 문서](../porting/README.md) 참고).

---

## 6. 관측

| 대상 | 저장 | 소비처 |
|---|---|---|
| 요청별 토큰 사용량 | `usage.jsonl` (append) | 통계 화면, 캐시 손실 분석 |
| 스왑 이벤트 | `audit.jsonl` (append) | 타임라인 |
| 지속 조건 (cross-plan, 계정 무효 등) | 메모리 + 스냅샷 | 배너, 뱃지 |
| 진단 로그 | `diagnostic.log` (회전) | 문제 신고 |

`usage.jsonl` 에 `cache_creation_input_tokens` 와 `cache_read_input_tokens` 를 반드시
남긴다. `audit.jsonl` 의 스왑 시각과 조인하면 **스왑 때문에 재생성된 캐시 토큰**을 뽑을 수
있고, 이것이 우선순위 체인 설계와 선제 전환 임계값의 유일한 실증 데이터다.

---

## 7. 디렉토리 레이아웃

```
clf/
+-- Package.swift
+-- Sources/
|   +-- ClfCore/
|   |   +-- Headers/          HeaderBag, ProxyHeaders
|   |   +-- Classification/   SwapTrigger, classifyResponse, resolveResetEpoch
|   |   +-- SSE/              findSSEBoundary, SSEParser, peek 알고리즘
|   |   +-- Selection/        AccountSelector, 쿨다운 산술
|   |   `-- Model/            Account, AccountRuntime, RoutingEvent
|   +-- ClfStore/
|   |   +-- CredentialStore.swift
|   |   +-- AccountsFile.swift, RuntimeFile.swift
|   |   +-- JSONLSink.swift
|   |   `-- ClaudeSettings.swift
|   +-- ClfProxy/
|   |   +-- ProxyServer.swift
|   |   +-- Router.swift          (actor)
|   |   +-- UpstreamExecutor.swift
|   |   `-- RelayPump.swift
|   +-- ClfDesktop/          남의 앱 읽기, 계정별 창, 세션 옮기기
|   +-- ClfApp/
|   |   +-- ClfAppMain.swift      (MenuBarExtra)
|   |   +-- UsageModel.swift      (@MainActor 상태 하나)
|   |   `-- Views.swift, DotBlock.swift, BarLabel.swift, Handoff*.swift
|   `-- clfctl/
+-- scripts/                 build, make-app, install-app, install-clfctl
+-- tools/make-icon.swift
+-- dev.sh                   디버그 빌드 후 터미널에 붙여 띄운다
`-- Tests/
    +-- ClfCoreTests/        <- claulay 테스트 케이스 이식본
    +-- ClfStoreTests/
    +-- ClfDesktopTests/     데스크톱 트랙 판단 전부
    `-- ClfProxyTests/
```

파일 하나하나는 [04 문서](04-implementation.md) 3절에 있다.

앱 데이터는 macOS 관례를 따른다.

```
~/Library/Application Support/clf/
+-- accounts.json      계정 메타데이터 + 우선순위 (토큰 없음)
+-- runtime.json       계정별 런타임 상태 (쿨다운, 무효화, ratelimit 스냅샷)
+-- desktop.json       메뉴바 앱 설정 (보는 계정, 막대 구성, 알림)
+-- usage.jsonl
+-- audit.jsonl
`-- diagnostic.log
```

각 파일의 스키마와 영속화 근거는 [02 문서](02-domain-model.md) 6절.

토큰은 Keychain 에만 존재한다. claulay 의 `~/.claulay/` 에서 가져오는 임포트 경로는
별도로 둔다.
