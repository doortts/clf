# 04. 구현 설계

코드를 치기 직전 수준. 패키지 구성, 의존성 결정, 타겟별 공개 API, 동시성 주석,
오류 처리, 테스트 전략, 배포.

[01 아키텍처](01-architecture.md) 가 경계를, [02 도메인 모델](02-domain-model.md) 이
타입을, [03 요청 흐름](03-request-flow.md) 이 동작을 정했다. 이 문서는 그것을 Swift
프로젝트 구조로 옮긴다.

---

## 1. 의존성 결정

### 로컬 서버: swift-nio 직접

Vapor 나 Hummingbird 같은 웹 프레임워크를 쓰지 않는다.

- 라우팅, 미들웨어, 템플릿, 콘텐츠 협상이 전혀 필요없다. 경로 하나를 그대로 흘려보낸다
- SSE 릴레이는 바이트 단위 제어가 필요한데 프레임워크는 그 층을 감춘다
- 메뉴바 상주 앱이라 바이너리와 메모리를 아껴야 한다

`NIOAsyncChannel`(NIO 2.60+)을 쓴다. 채널 핸들러를 직접 쓰지 않고 `for try await` 로
인바운드 HTTP 파트를 받는다. 나머지 코드가 전부 async/await 이므로 경계를 하나 줄인다.

### 업스트림: AsyncHTTPClient

- 응답 본문이 `AsyncSequence<ByteBuffer>` 다. [포팅 03](../porting/03-sse-streaming.md) 의
  peek 설계가 iterator 를 들고 이어 도는 것을 전제하므로 그대로 맞는다
- NIO 위에 있어 서버와 `EventLoopGroup` 을 공유한다
- 취소가 Swift 구조적 동시성으로 전파된다

`URLSession` 은 쓰지 않는다. 커넥션 풀 제어가 약하고 NIO 이벤트 루프와 섞으면 스레드
경계가 하나 더 생긴다.

### 압축 해제를 반드시 켠다

```swift
HTTPClient.Configuration(
    decompression: .enabled(limit: .ratio(25))   // 기본값은 .disabled
)
```

**끄면 스왑 판정이 죽는다.** 첫 SSE 프레임에서 `\n\n` 경계를 찾고 `error.type` 을
읽어야 하는데 gzip 바이트에는 둘 다 없다. 해제한 평문을 내보내므로 응답 헤더의
`content-encoding` 은 제거한다 ([포팅 01](../porting/01-headers-and-auth.md) 5절).

`.ratio(25)` 는 zip bomb 가드다. SSE JSON 은 압축률이 높아 10 배로는 부족하다.

### 그 외

로깅 라이브러리를 넣지 않는다. 진단 로그는 JSONL 한 줄을 붙이는 것이 전부라 60줄이면
되고, `swift-log` 를 넣으면 백엔드 설정이라는 결정이 하나 더 생긴다.

```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
]
```

---

## 2. Package.swift

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "clfl",
    platforms: [.macOS(.v13)],          // MenuBarExtra 요구 사항
    products: [
        .library(name: "ClflCore",  targets: ["ClflCore"]),
        .library(name: "ClflStore", targets: ["ClflStore"]),
        .library(name: "ClflProxy", targets: ["ClflProxy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    ],
    targets: [
        .target(name: "ClflCore"),                       // 의존성 0. 이것이 규칙이다
        .target(name: "ClflStore", dependencies: ["ClflCore"]),
        .target(name: "ClflProxy", dependencies: [
            "ClflCore", "ClflStore",
            .product(name: "NIOCore",        package: "swift-nio"),
            .product(name: "NIOPosix",       package: "swift-nio"),
            .product(name: "NIOHTTP1",       package: "swift-nio"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
        ]),
        .testTarget(name: "ClflCoreTests",  dependencies: ["ClflCore"]),
        .testTarget(name: "ClflStoreTests", dependencies: ["ClflStore"]),
        .testTarget(name: "ClflProxyTests", dependencies: ["ClflProxy"]),
    ],
    swiftLanguageModes: [.v6]
)
```

`ClflApp` 은 패키지 타겟이 아니라 **Xcode 앱 타겟**이다. 앱 번들, Info.plist,
서명, 리소스가 필요해 SPM 실행 타겟으로는 만들 수 없다. Xcode 프로젝트가 이 패키지를
로컬 의존성으로 참조한다.

**`ClflCore` 의 의존성이 0인 것이 이 구성의 핵심이다.** 여기에 NIO 가 한 번 들어오면
테스트가 이벤트 루프를 필요로 하기 시작하고, claulay 에서 옮겨올 오프라인 테스트
자산이 무너진다.

---

## 3. 파일 목록

```
Sources/ClflCore/
+-- Model/
|   +-- Account.swift              Account, Plan, AccountID, ModelID, SessionID
|   +-- AccountRuntime.swift       AccountRuntime, RateLimitSnapshot, Availability
|   +-- RoutingEvent.swift         RoutingEvent, Condition, Usage
|   `-- Clock.swift                protocol Clock, SystemClock, FixedClock
+-- Headers/
|   +-- HeaderBag.swift            케이스 무시 헤더 백
|   `-- ProxyHeaders.swift         blocklist, rewriteAuth, mergeBetaFlag, buildUpstreamURL
+-- Classification/
|   +-- SwapTrigger.swift          SwapTrigger, ClassifyInput
|   +-- ResponseClassifier.swift   classifyResponse, extractErrorType
|   +-- ResetEpoch.swift           resolveResetEpoch
|   `-- TransientOverload.swift    isTransientOverload
+-- SSE/
|   +-- SSEBoundary.swift          findSSEBoundary, isCommentOnlyFrame
|   +-- SSEParser.swift            SSEEvent, SSEParser
|   `-- UsageSniffer.swift         message_delta 에서 토큰 수 추출
`-- Selection/
    +-- AccountSelector.swift      select, SelectionInput, SelectionResult
    +-- Cooldown.swift             availability, 쿨다운 산술
    +-- Headroom.swift             band, 잔여 계산
    `-- ShortCode.swift            shortCodes, mostRecentOther

Sources/ClflStore/
+-- KeychainTokenStore.swift       TokenStoring 구현
+-- AccountsFile.swift             accounts.json 읽기/쓰기
+-- RuntimeFile.swift              runtime.json. debounce + 원자적 교체
+-- JSONLSink.swift                usage.jsonl, audit.jsonl append
+-- DiagnosticLog.swift            회전 로그
+-- ClaudeSettings.swift           ~/.claude/settings.json 병합 편집
`-- AtomicWrite.swift              tmp + rename + 0600

Sources/ClflProxy/
+-- Router.swift                   actor. 런타임 상태의 단일 소유자
+-- ProxyServer.swift              NIOAsyncChannel 수신, 요청당 Task
+-- RequestPipeline.swift          body 버퍼링, model/session 추출, 스왑 루프
+-- UpstreamExecutor.swift         AsyncHTTPClient 실행. UpstreamAttempt 생성
+-- SSEPeek.swift                  peekFirstSSEFrame (Core 알고리즘 + NIO 타입)
+-- RelayPump.swift                클라이언트 릴레이. once-write 불변식
`-- ProxyError.swift

앱 타겟 (Xcode)
ClflApp/
+-- ClflApp.swift                  @main, MenuBarExtra
+-- AppModel.swift                 @MainActor @Observable. Router 스냅샷 소비
+-- Views/MenuBarLabel.swift
+-- Views/PopoverView.swift
+-- Views/Settings/*.swift
+-- LoginItem.swift                SMAppService
`-- Info.plist                     LSUIElement
```

---

## 4. 타겟별 공개 API

### ClflCore

전부 순수하다. `Date()` 를 내부에서 부르는 곳이 하나도 없어야 한다.

```swift
// Clock. 모든 시각은 인자로 들어온다
public protocol Clock: Sendable { var now: Date { get } }
public struct SystemClock: Clock { public var now: Date { Date() } }
public struct FixedClock: Clock { public var now: Date }     // 테스트용

// Headers
public func stripClientHopByHop(_ h: HeaderBag) -> HeaderBag
public func rewriteAuth(_ h: HeaderBag, token: String) -> HeaderBag
public func injectAnthropicVersion(_ h: HeaderBag, default: String) -> HeaderBag
public func pickResponseHeaders(_ h: HeaderBag, clientDecodedBody: Bool) -> HeaderBag
public func buildUpstreamURL(baseURL: String, requestURI: String) -> String

// Classification
public func classifyResponse(_ input: ClassifyInput) -> SwapTrigger?
public func resolveResetEpoch(_ h: HeaderBag, now: Int) -> Int
public func isTransientOverload(headers: HeaderBag, trigger: SwapTrigger) -> Bool

// SSE. 바이트만 다루고 스트림은 모른다
public func findSSEBoundary(_ bytes: [UInt8], from: Int) -> SSEBoundary?
public func isCommentOnlyFrame(_ content: ArraySlice<UInt8>) -> Bool
public struct SSEParser: Sendable { mutating func push(_: [UInt8]) -> [SSEEvent] ... }

// Selection
public func select(_ input: SelectionInput) -> SelectionResult
public func availability(_ r: AccountRuntime, for: ModelID, now: Date,
                         activeID: AccountID?, id: AccountID) -> Availability
public func band(remaining: Double, lowThreshold: Double) -> HeadroomBand
public func shortCodes(for ids: [AccountID]) -> [AccountID: String]
```

**peek 이 Core 에 없는 이유.** `findSSEBoundary` 는 Core 에 있지만
`peekFirstSSEFrame` 은 Proxy 에 있다. 전자는 바이트 배열 함수라 순수하고, 후자는
`AsyncIterator` 를 소비하므로 스트림 타입에 묶인다. **경계를 찾는 알고리즘과 그것을
스트림에 적용하는 루프를 분리**하면 어려운 쪽(경계 판정, 주석 건너뛰기, 청크 걸침)이
전부 오프라인 테스트 대상이 된다.

### ClflStore

```swift
public protocol TokenStoring: Sendable {
    func token(for id: AccountID) throws -> String
    func store(_ token: String, for id: AccountID) throws
    func remove(_ id: AccountID) throws
    func hasToken(for id: AccountID) -> Bool          // 값을 읽지 않고 존재만 확인
}

public protocol ClaudeSettingsManaging: Sendable {
    func readManagedBaseURL() throws -> URL?
    func install(baseURL: URL, enableToolSearch: Bool, force: Bool) throws
    func uninstall() throws
}

public protocol EventSinking: Sendable {                 // best-effort. throws 하지 않는다
    func append(_ event: RoutingEvent)
    func append(_ usage: UsageRecord)
}

public actor AccountsFile { ... }   // load/save accounts.json
public actor RuntimeFile  { ... }   // load/save runtime.json, 1초 debounce
```

`hasToken` 이 따로 있는 이유는 점검 화면 때문이다. 토큰 존재만 확인하는 데 Keychain
잠금 해제 프롬프트를 띄우면 안 된다.

### ClflProxy

```swift
public actor Router {
    public func snapshot() -> RouterSnapshot                    // 값 타입 깊은 복사
    public func select(model: ModelID, tried: Set<AccountID>,
                       isConversationStart: Bool) -> SelectionResult
    public func apply(_ outcome: RoutingOutcome, to id: AccountID)
    public var changes: AsyncStream<RouterSnapshot> { get }     // UI 구독용
}

public protocol UpstreamExecuting: Sendable {
    func execute(_ req: UpstreamRequest) async throws -> UpstreamAttempt
}

public struct ProxyServer: Sendable {
    public init(router: Router, executor: UpstreamExecuting, ...)
    public func start(port: UInt16) async throws -> UInt16      // 실제 바인딩된 포트
    public func shutdown() async
}
```

---

## 5. 동시성 주석 규칙

Swift 6 strict concurrency 를 켠다. `@unchecked Sendable` 은 금지한다. 필요해지면
설계가 틀린 것이다.

| 대상 | 주석 | 근거 |
|---|---|---|
| ClflCore 전 타입 | `Sendable` (값 타입) | 순수 데이터. 공유해도 안전 |
| `Router` | `actor` | 런타임 상태의 유일한 가변 소유자 |
| `AccountsFile`, `RuntimeFile` | `actor` | 파일 쓰기 직렬화 + debounce 타이머 소유 |
| `KeychainTokenStore` | `struct: Sendable` | Keychain API 자체가 스레드 안전 |
| `JSONLSink` | `actor` | append 순서 보장 |
| `AppModel`, 모든 View | `@MainActor` | SwiftUI |
| 요청 처리 | `Task` 하나 | 요청당 독립. 공유 상태는 Router 를 통해서만 |

### 절대 규칙: Router 는 I/O 를 await 하지 않는다

```swift
// 요청 Task 안에서
var tried: Set<AccountID> = []
while tried.count < priorityCount {
    let result = await router.select(model: model, tried: tried, ...)
    guard case .selected(let sel) = result else { break }

    let token   = try tokens.token(for: sel.accountID)      // actor 밖
    let attempt = try await executor.execute(...)            // actor 밖. 여기가 길다
    let trigger = classifyResponse(...)                      // 순수 함수

    guard let trigger else { break }                          // 통과
    await router.apply(outcome(trigger), to: sel.accountID)   // 짧게 다시 들어감
    tried.insert(sel.accountID)
}
```

`router.select` 와 `router.apply` 는 둘 다 마이크로초 단위여야 한다. 네트워크 왕복을
actor 안에서 기다리면 동시 요청 전체가 직렬화된다.

### UI 갱신

Router 가 `AsyncStream<RouterSnapshot>` 을 내보내고 `AppModel` 이 `@MainActor` 에서
소비한다. 스냅샷은 값 타입이므로 경계를 넘는 데 문제가 없다.

```swift
@MainActor @Observable final class AppModel {
    private(set) var snapshot = RouterSnapshot.empty
    func observe(_ router: Router) {
        Task { for await s in await router.changes { self.snapshot = s } }
    }
}
```

**갱신을 병합한다.** 요청이 몰리면 스냅샷이 초당 수십 번 나올 수 있다. 메뉴바는 그렇게
자주 다시 그릴 이유가 없으므로 Router 쪽에서 100ms 단위로 합쳐 내보낸다.

---

## 6. 오류 처리

### 두 부류로 나눈다

**요청 경로를 막아도 되는 것** - `throws` 로 올린다.

```swift
public enum ProxyError: Error, Sendable {
    case noAccountAvailable(unblockable: [AccountID])
    case tokenUnavailable(AccountID)
    case upstreamFailed(underlying: Error)
    case clientDisconnected
}
```

**막으면 안 되는 것** - 삼키고 진단 로그에만 남긴다.

- `usage.jsonl` / `audit.jsonl` append 실패
- `runtime.json` 쓰기 실패
- 진단 로그 자체의 쓰기 실패

그래서 `EventSinking` 의 메서드에 `throws` 가 없다. **타입으로 강제한다.** 호출부에서
`try?` 를 쓰는 규율에 기대면 언젠가 새어나온다.

디스크가 가득 차서 로그를 못 써도 프록시는 계속 돌아야 한다
([03 요청 흐름](03-request-flow.md) 4절).

### 사용자에게 보이는 오류

`ProxyError` 를 그대로 보여주지 않는다. `Condition` 으로 번역해서 배너와 점검 화면이
읽는다. 오류 문구는 무엇이 잘못됐는지와 어떻게 고치는지를 함께 말한다.

---

## 7. 테스트 전략

### ClflCoreTests: claulay 자산 이식

[포팅 문서](../porting/README.md) 각 장 끝의 테스트 케이스 목록이 그대로 여기 온다.
네트워크도 파일도 시계도 없다.

```
ClflCoreTests/
+-- HeadersTests.swift          rewriteAuth OAuth 분기 5개 포함
+-- ClassifierTests.swift       429/401/통과 분기, resolveResetEpoch 6개
+-- SSEBoundaryTests.swift      분할 패킷, CRLF, 주석 프레임, 8KiB 초과
+-- SSEParserTests.swift        멀티바이트 청크 경계 포함
+-- SelectorTests.swift         FixedClock 으로 쿨다운 만료 경계
+-- HeadroomTests.swift         밴드 경계값 (4.9 / 5.0 / 14.9 / 15.0 / 49.9 / 50.0)
`-- ShortCodeTests.swift        재번호, 앞 2글자 충돌
```

### Fixtures

claulay 테스트에 들어있는 실제 Anthropic 응답 모양을 파일로 떠 온다.

```
Tests/Fixtures/
+-- rate_limit_429.json
+-- session_limit_429.json
+-- auth_401.json
+-- overloaded_529.json
+-- sse_error_first_frame.txt
+-- sse_normal_stream.txt
`-- sse_keepalive_prefix.txt
```

손으로 만든 JSON 이 아니라 **실제 응답의 복사본**이어야 한다. 필드 하나 빠뜨린 가짜
fixture 로 통과하는 테스트는 가치가 없다.

### ClflProxyTests: 가짜 executor 로 스왑 루프

```swift
struct ScriptedExecutor: UpstreamExecuting {
    let script: [Result<UpstreamAttempt, Error>]    // 호출 순서대로 소비
    func execute(_ req: UpstreamRequest) async throws -> UpstreamAttempt { ... }
}
```

검증 대상:

- 429 시퀀스에서 계정이 우선순위 순으로 선택되는가
- 같은 요청 안에서 같은 계정을 두 번 시도하지 않는가
- 체인 소진 시 마지막 실패 응답을 원문 그대로 재생하는가
- `.exhausted(unblockable:)` 에 제외 계정이 실리는가
- 클라이언트 쓰기가 판정 전에 일어나지 않는가 (once-write)

마지막 항목이 가장 중요하다. `ClientResponseWriter` 를 가짜로 두고 `writeHead` 호출
횟수와 시점을 기록해서 검증한다.

### 통합 테스트는 얇게

로컬 스텁 서버를 띄워 실제 소켓으로 도는 테스트는 3개면 된다. 정상 스트림 통과,
첫 프레임 에러로 스왑, 클라이언트 중단 시 업스트림 취소. 나머지는 전부 단위 테스트로
잡는다.

---

## 8. 앱 번들과 배포

### 샌드박스를 끈다

**App Sandbox 를 켜면 `~/.claude/settings.json` 을 쓸 수 없다.** 이 앱의 존재 이유가
그 파일을 관리하는 것이므로 샌드박스는 선택지가 아니다.

- App Store 배포 불가. 어차피 사내 도구라 해당 없음
- Developer ID 서명 + notarization 으로 배포한다
- Hardened Runtime 은 켠다. 샌드박스와 별개다

### Info.plist

```xml
<key>LSUIElement</key><true/>              <!-- Dock 아이콘 없음 -->
<key>LSMinimumSystemVersion</key><string>13.0</string>
```

### 로그인 항목

```swift
import ServiceManagement
try SMAppService.mainApp.register()      // macOS 13+
```

사용자가 설정 창에서 켜고 끈다. 기본값은 꺼짐 - 처음 실행에서 묻지 않고, 실제로
쓰기 시작한 뒤에 권유한다.

### 배포 경로

사내 배포이므로 Sparkle 같은 자동 업데이트 프레임워크를 1차에 넣지 않는다. 새 버전을
알리는 것은 나중 문제고, 지금은 `.dmg` 를 사내 저장소에 올리는 것으로 충분하다.

---

## 9. 첫 두 주 작업 순서

[03 요청 흐름](03-request-flow.md) 7절의 11단계를 실제 순서로 편다.

| 순서 | 할 일 | 끝났다는 기준 |
|---|---|---|
| 1 | 패키지 스캐폴딩, ClflCore 빈 타겟, CI 없이 `swift test` | 빈 테스트가 돈다 |
| 2 | HeaderBag, ProxyHeaders + 테스트 | claulay headers.test.ts 케이스 전부 통과 |
| 3 | Classification + ResetEpoch + 테스트 | claulay interceptor.test.ts 케이스 전부 통과 |
| 4 | SSE 경계 스캐너, 파서 + 테스트 | 분할 패킷과 멀티바이트 케이스 통과 |
| 5 | Selection, Cooldown, Headroom, ShortCode + 테스트 | FixedClock 으로 경계값 통과 |
| 6 | ClflStore: Keychain, accounts.json, runtime.json | 임시 디렉토리 단위 테스트 |
| 7 | UpstreamExecutor + SSEPeek | 실제 api.anthropic.com 에 한 번 붙어본다 |
| 8 | ProxyServer 단일 계정 통과 (스왑 없음) | **Claude Code 데스크톱 앱으로 대화 성공** |

**8번이 첫 관문이다.** 여기서 [README](../../README.md) 에 적은 MCP tool search 와
Remote Control 제약이 실제로 어떻게 나타나는지, `X-Claude-Session-Id` 헤더가 오는지
([02 도메인 모델](02-domain-model.md) 3절의 검증 항목) 전부 드러난다.

1번부터 6번까지는 네트워크 없이 돈다. 실제 계정이나 토큰 없이도 절반 이상을 만들고
검증할 수 있다는 뜻이다.

---

## 10. 아직 정하지 않은 것

| 항목 | 언제 정하나 |
|---|---|
| 선제 전환 임계값의 실제 값 | usage/audit 조인으로 캐시 재생성 비용을 측정한 뒤 |
| Agent View MITM 지원 | 1차 범위 밖. 필요하다는 사용자가 생기면 |
| 수동 계정 고정 | 자동 전환 제외를 써보고 부족하면 |
| 자동 업데이트 | 사내 배포가 자리 잡은 뒤 |
| Windows | 프록시 코어는 이식 가능. daemon 계층이 없으므로 열려 있다 |
