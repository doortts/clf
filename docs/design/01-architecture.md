# 01. 아키텍처

시스템 경계, 모듈 분해, 동시성 모델, 프로세스 수명.

---

## 1. 시스템 경계

clfl이 소유하는 것과 소유하지 않는 것을 먼저 못박는다.

```
  [Claude Code 데스크톱 앱]         <- clfl이 소유하지 않음. 건드리는 것은
            |                          ~/.claude/settings.json 의 env 블록 한 줄뿐
            | HTTP (127.0.0.1:고정포트)
            v
  +---------------------------------------+
  |  clfl.app  (LSUIElement, 상시 실행)   |
  |                                       |
  |   MenuBarExtra UI                     |
  |   Router (계정 선택, 쿨다운)          |
  |   ProxyServer (peek, 분류, 릴레이)    |
  |   Store (Keychain, 설정, 로그)        |
  +---------------------------------------+
            |
            | HTTPS
            v
  [api.anthropic.com]  또는 계정별 base_url
```

clfl은 **대화를 소유하지 않는다.** Messages API는 stateless이고 전체 이력은 매 요청
body에 담겨 온다. clfl이 하는 일은 요청 하나에 어떤 인증 헤더를 붙일지 정하는 것뿐이다.

### 소유하지 않기로 한 것

| 항목 | 이유 |
|---|---|
| 대화 실행 UI | Claude Code 데스크톱 앱의 일. clfl은 라우팅만 |
| `~/.claude/` 의 나머지 전부 | settings.json 의 `env` 블록 외에는 읽지도 쓰지도 않는다 |
| 계정별 CLAUDE.md / skills / memory | 프록시가 credential 을 주입하므로 설정 디렉토리는 identity 무관하게 유지 |
| Agent View 백그라운드 워커 (MITM) | 1차 범위 밖. 4절 참고 |

---

## 2. 모듈 분해

Swift Package Manager 타겟 4개. **의존은 한 방향으로만 흐른다.**

```
ClflApp        (SwiftUI, MenuBarExtra, MainActor)
   |
   +--> ClflProxy   (NIO / AsyncHTTPClient, 서버와 업스트림)
   |       |
   +-------+--> ClflStore   (Keychain, 설정 파일, JSONL 로그)
   |       |       |
   +-------+-------+--> ClflCore   (순수 도메인. I/O 없음, AppKit 없음)
```

| 타겟 | 담는 것 | 담지 않는 것 |
|---|---|---|
| **ClflCore** | HeaderBag, 헤더 변환, 응답 분류, reset epoch 계산, SSE 경계 스캐너/파서, 계정 선택 알고리즘, 쿨다운 산술 | 네트워크, 파일, 시계, 로그 |
| **ClflStore** | Keychain 토큰, 계정/우선순위 영속화, 모델 쿨다운 캐시, usage/audit JSONL, `~/.claude/settings.json` 관리 | 라우팅 판단 |
| **ClflProxy** | 로컬 HTTP 서버, 업스트림 실행기, peek/릴레이 펌프, Router actor | 헤더/분류 규칙 (Core 호출) |
| **ClflApp** | MenuBarExtra, 팝오버, 설정 창, 알림, 로그인 항목 등록 | 라우팅 상태의 원본 |

### ClflCore 를 순수하게 유지하는 이유

claulay 가 가장 잘한 설계다. `swap.ts` 주석의 표현을 빌리면 "purity posture: 루프는
주입된 의존성만 만지고 모든 I/O 는 deps 객체를 통과하므로 단위 테스트가 오프라인에서
돈다".

그 결과 claulay 는 소스와 맞먹는 분량의 테스트를 네트워크 없이 돌린다. 우리가 옮기려는
지식([포팅 문서](../porting/README.md))이 전부 그 테스트 안에 있으므로, **같은 경계를
유지해야 그 테스트를 그대로 옮길 수 있다.**

규칙:

- ClflCore 의 모든 함수는 입력 -> 출력 순수 함수이거나, 값 타입 상태를 받아 새 값을 낸다
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
뜨고 죽었으므로 "프록시가 없는 상태" 자체가 정상이었다. clfl 은 아니다.

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
- 최초 쓰기 전에 `settings.json.clfl.bak` 로 백업
- 우리가 만지는 키는 `env.ANTHROPIC_BASE_URL` 과 (옵션) `env.ENABLE_TOOL_SEARCH` 뿐
- 이미 다른 값이 들어 있으면 거부하고 사용자에게 알린다. `force` 로만 덮어쓴다
- `CLAUDE_CONFIG_DIR` 환경변수가 있으면 그 경로를 쓴다

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
그대로 ClflCore 테스트가 된다 ([포팅 문서](../porting/README.md) 참고).

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
clfl/
+-- Package.swift
+-- Sources/
|   +-- ClflCore/
|   |   +-- Headers/          HeaderBag, ProxyHeaders
|   |   +-- Classification/   SwapTrigger, classifyResponse, resolveResetEpoch
|   |   +-- SSE/              findSSEBoundary, SSEParser, peek 알고리즘
|   |   +-- Selection/        AccountSelector, 쿨다운 산술
|   |   `-- Model/            Account, AccountRuntime, RoutingEvent
|   +-- ClflStore/
|   |   +-- KeychainTokenStore.swift
|   |   +-- ConfigStore.swift
|   |   +-- JSONLSink.swift
|   |   `-- ClaudeSettings.swift
|   +-- ClflProxy/
|   |   +-- ProxyServer.swift
|   |   +-- Router.swift          (actor)
|   |   +-- UpstreamExecutor.swift
|   |   `-- RelayPump.swift
|   `-- ClflApp/
|       +-- ClflApp.swift         (MenuBarExtra)
|       +-- ViewModels/
|       `-- Views/
`-- Tests/
    +-- ClflCoreTests/        <- claulay 테스트 케이스 이식본
    +-- ClflStoreTests/
    `-- ClflProxyTests/
```

앱 데이터는 macOS 관례를 따른다.

```
~/Library/Application Support/clfl/
+-- accounts.json      계정 메타데이터 + 우선순위 (토큰 없음)
+-- runtime.json       계정별 런타임 상태 (쿨다운, 무효화, ratelimit 스냅샷)
+-- usage.jsonl
+-- audit.jsonl
`-- diagnostic.log
```

각 파일의 스키마와 영속화 근거는 [02 문서](02-domain-model.md) 6절.

토큰은 Keychain 에만 존재한다. claulay 의 `~/.claulay/` 에서 가져오는 임포트 경로는
별도로 둔다.
