# 02. 도메인 모델과 계정 선택

ClflCore 가 다루는 타입, 계정 상태의 정의, 선택 알고리즘, 영속화 분할.

---

## 1. 기본 타입

```swift
typealias AccountID = String
typealias ModelID   = String        // 요청 body 의 `model` 값을 그대로 쓴다
typealias SessionID = String        // X-Claude-Session-Id 헤더

enum Plan: String, Codable, Sendable { case team, enterprise }

struct Account: Codable, Identifiable, Sendable {
    let id: AccountID               // 사용자 지정. 우선순위 체인의 식별자
    var plan: Plan
    var baseURL: URL?               // nil 이면 https://api.anthropic.com
    var note: String?

    /// false 면 자동 전환 후보에서 뺀다. 계정과 토큰은 그대로 남는다.
    /// 기본값이 true 라 기존 계정의 동작은 바뀌지 않는다. 자세한 것은 3-3절.
    var autoSwitch: Bool = true

    /// 자격증명 종류. oauth 는 갱신 가능하고 모델별 한도를 볼 수 있다.
    /// [07 문서](07-oauth-credentials.md) 8절
    var credentialKind: CredentialKind

    /// 토큰 등록 시각. longLived 는 1년짜리라 만료를 미리 알려야 한다.
    var tokenCreatedAt: Date

    /// 토큰 문자열의 SHA-256 앞 8바이트. 같은 토큰을 두 번 등록하는 실수를 막는다.
    /// 신원 확인용이 아니다. 토큰 자체는 Keychain 에만 있다. [05 문서](05-account-registration.md) 6절
    var tokenFingerprint: String
}
```

토큰은 `Account` 에 없다. Keychain 에만 있고 `AccountID` 로 조회한다. 이렇게 하면
계정 목록을 UI 로 넘기거나 로그에 찍어도 비밀이 새지 않는다.

---

## 2. 런타임 상태

```swift
struct AccountRuntime: Codable, Sendable {
    var lastUsedAt: Date?

    /// 401 을 맞은 시각. 시간으로 회복되지 않으며 사용자가 재로그인해야 한다.
    var invalidatedAt: Date?

    /// session_limit_error 로 인한 계정 전체 쿨다운.
    var accountCooldownUntil: Date?

    /// rate_limit_error 로 인한 (계정, 모델) 쿨다운.
    /// 한 모델이 소진돼도 같은 계정의 다른 모델은 계속 쓸 수 있어야 한다.
    var modelCooldowns: [ModelID: Date] = [:]

    /// 응답 헤더에서 추적한 잔여량. 선제 전환 판단과 UI 게이지의 유일한 소스.
    var rateLimit: RateLimitSnapshot?
}

struct Window: Codable, Sendable {
    var usedRatio: Double               // 0.0 ~ 1.0. 서버가 주는 것은 사용률이다
    var resetsAt: Date?
    var remaining: Double { 1 - usedRatio }
}

struct RateLimitSnapshot: Codable, Sendable {
    var fiveHour: Window?
    var sevenDayAll: Window?            // 전체 모델 주간

    /// 모델별 주간 창. **Usage API 의 `limits[]` 에서만 온다. 응답 헤더에는 없다.**
    /// Claude Code 가 보여주는 "Weekly, Fable" 행이 이것이다.
    var modelWeekly: [ModelID: Window] = [:]

    var observedAt: Date
    var source: Source

    enum Source: String, Codable, Sendable {
        case headers        // 응답 헤더 편승. 5시간과 전체 주간만
        case usageAPI       // 모델별 주간까지. user:profile 스코프 필요
    }
}
```

### 상태를 enum 으로 저장하지 않고 파생시킨다

계정의 "상태"는 저장 대상이 아니라 계산 결과다. 저장하면 시각이 흐르면서 stale 해진다.

```swift
enum Availability: Sendable {
    case active                                     // 지금 이 요청이 쓰는 계정
    case ready
    case cooling(until: Date, scope: CooldownScope)
    case invalid(since: Date)
}

enum CooldownScope: Sendable {
    case account            // session_limit. 모든 모델이 막힘
    case model(ModelID)     // rate_limit. 그 모델만 막힘
}

func availability(
    _ r: AccountRuntime, for model: ModelID, now: Date, activeID: AccountID?, id: AccountID
) -> Availability {
    if let at = r.invalidatedAt { return .invalid(since: at) }
    if let until = r.accountCooldownUntil, until > now {
        return .cooling(until: until, scope: .account)
    }
    if let until = r.modelCooldowns[model], until > now {
        return .cooling(until: until, scope: .model(model))
    }
    return id == activeID ? .active : .ready
}
```

**모델 범위 쿨다운이 이 모델의 핵심이다.** 같은 계정이 `fable` 에 대해서는 cooling 이고
`opus` 에 대해서는 ready 일 수 있다. 그래서 `availability` 가 `model` 을 인자로 받는다.

### 상태 전이

```
                   +---------------------------------------+
                   |                                       |
                   v                                       |
   (신규 등록) -> ready -- 선택됨 --> active               | 쿨다운 만료
                   ^                   |                   | 또는 사용자 reset
                   |                   |                   |
                   |          +--------+--------+          |
                   |          |                 |          |
                   |     429 session       429 rate        |
                   |          |                 |          |
                   |          v                 v          |
                   |    cooling(account)  cooling(model) ---+
                   |                            |
                   |                            +-- 다른 모델은 계속 ready
                   |
                   +---- 사용자 재로그인 ---- invalid <---- 401 (어느 상태에서든)
```

`invalid` 만 시간으로 회복되지 않는다. 나머지는 전부 시각 비교로 자동 해제된다.

---

## 3. 계정 선택

```swift
struct Selection: Sendable {
    let accountID: AccountID
    let plan: Plan
    let baseURL: URL
    let isCrossPlan: Bool       // 직전 활성 계정과 plan 이 다른가
}

enum SelectionResult: Sendable {
    case selected(Selection)
    /// 회복 가능한 계정이 있으나 아직 쿨다운 중. grace 예산 안에서 대기 후 재훑기.
    case wait(until: Date)
    /// 시간으로 회복되지 않는다. 자동 전환에서 제외해 둔 계정 중 지금 쓸 수 있는
    /// 것이 있으면 함께 실어 보낸다. UI 가 "이번만 사용" 을 제안할 근거가 된다.
    case exhausted(unblockable: [AccountID])
}
```

### 알고리즘

```swift
struct SelectionInput: Sendable {
    let priority: [AccountID]
    let accounts: [AccountID: Account]
    let runtime: [AccountID: AccountRuntime]
    let model: ModelID
    let now: Date
    let tried: Set<AccountID>           // 이 요청에서 이미 시도한 계정
    let activeID: AccountID?
    let isConversationStart: Bool       // 선제 강등을 적용할지
    let proactiveThreshold: Double      // 잔여 기준. 기본 0.15
    let proactiveHysteresis: Double     // tier 0 진입선을 올린다. 기본 0.10
}

func select(_ input: SelectionInput) -> SelectionResult
```

순서:

1. 후보 = `priority` 순서에서 `tried` 를 뺀 것
2. **`autoSwitch == false` 제외** (3-3절). 건강 상태와 무관한 사용자 의사이므로 맨 앞에서 거른다
3. `invalid` 제외
4. `cooling(account)` 제외
5. `cooling(model)` 제외 (요청 모델과 일치할 때만)
6. **선제 강등** (아래 참고). 제외가 아니라 후순위로 민다
7. 남은 것 중 최상위 반환
8. 아무것도 없으면
   - 시간으로 회복 가능한 계정이 있으면 -> `.wait(가장 이른 해제 시각)`
   - 없으면 -> `.exhausted(unblockable:)`. `unblockable` 은 `autoSwitch` 만 켜면
     지금 바로 쓸 수 있는 계정 목록이다

8번의 구분이 중요하다. claulay 는 이 구분이 없어서 일시 과부하와 진짜 소진이 같은 경로로
흘렀고, 시작 시 풀 전체가 60초 암전되는 증상을 낳았다
([포팅 02](../porting/02-response-classification.md) 4절).

### 선제 강등

quota 가 차기 전에 미리 전환하되, **제외가 아니라 2단계 정렬**로 처리한다.
제외가 아닌 이유는 전 계정이 임계값을 넘었을 때 가용 계정이 0이 되면 안 되기 때문이다.
강등은 가용성을 절대 줄이지 않는다.

#### 묶는 창은 둘 중 더 빡빡한 쪽이다

계정을 묶는 것은 5시간과 7일 중 **먼저 바닥나는 쪽**이다. 잔여 기준이므로 최솟값을
쓴다(사용률 기준으로 보면 최댓값과 같다).

```swift
/// 이 요청을 묶는 창의 잔여 비율. 없으면 nil.
///
/// 세 창을 본다. 5시간, 전체 주간, 그리고 **요청한 모델의 주간**.
/// 마지막 것은 Usage API 가 있을 때만 채워지며, 없으면 두 창으로 자연스럽게 줄어든다.
///
/// resetsAt 이 지난 창의 읽기는 버린다. 그 창은 이미 리셋됐으므로 스냅샷이 말하는
/// 소비는 존재하지 않는다. 아직 안 지난 창이면 소비는 늘기만 하므로 묵은 값도
/// 유효한 하한이다.
///
/// requireKnownReset 은 resetsAt 을 모를 때의 처리를 가른다.
///   활성 계정 판단  -> true.  만료를 모르는 묵은 낮은 값이 강등을 유발하면 안 된다
///   후보 계정 판단  -> false. 묵은 낮은 값은 그 후보를 뒤로 밀 뿐이라 안전하다
func bindingHeadroom(
    _ s: RateLimitSnapshot?, for model: ModelID, now: Date, requireKnownReset: Bool
) -> Double? {
    guard let s else { return nil }
    func usable(_ remaining: Double?, _ resetsAt: Date?) -> Double? {
        guard let remaining else { return nil }
        guard let resetsAt else { return requireKnownReset ? nil : remaining }
        return resetsAt < now ? nil : remaining
    }
    return [usable(s.fiveHour?.remaining,          s.fiveHour?.resetsAt),
            usable(s.sevenDayAll?.remaining,        s.sevenDayAll?.resetsAt),
            usable(s.modelWeekly[model]?.remaining, s.modelWeekly[model]?.resetsAt)]
        .compactMap { $0 }.min()
}
```

**이걸 빠뜨리면 7일이 먼저 바닥나는 경우를 통째로 놓친다.** [시안](ui-spec.html)의
전환 직후 예시가 정확히 그 경우다. 5시간 53%, 7일 0%.

#### 모델별 주간 창이 세 번째 축이다

Claude Code 자체 화면이 세 줄을 보여준다.

```
5-hour limit          Resets in 3 hr 7 min    9%
Weekly, all models    Resets Fri 6:00 AM      6%
Weekly, Fable                                 0%
```

세 번째 줄은 **응답 헤더에 없다.** 헤더는 `anthropic-ratelimit-unified-5h` 와 `-7d` 뿐이고,
모델별 주간은 Usage API 응답의 `limits[]` 배열(`kind == "weekly_scoped"`)이 유일한 출처다.

그래서 이 값을 얻으려면 `user:profile` 스코프가 있는 토큰이 필요하다
([05 문서](05-account-registration.md)). 없으면 `modelWeekly` 가 비고 두 창으로
줄어든다. **기능이 사라지는 것이 아니라 해상도가 낮아진다.**

| 토큰 | 보이는 창 | 모델별 한도 대응 |
|---|---|---|
| 전체 스코프 | 5시간, 전체 주간, **모델별 주간** | 벽에 닿기 전에 옮긴다 |
| 추론 전용 | 5시간, 전체 주간 | 429 를 맞고 나서 그 모델만 쿨다운 |

#### 2단계 정렬과 hysteresis

```
tier 0 : bindingHeadroom >= threshold + hysteresis     (선호)
tier 1 : 그 외 (읽기 없음 포함)                          (tier 0 이 비었을 때만)

각 tier 안에서는 priority 순서 유지
```

hysteresis 가 없으면 임계값 바로 위아래에 있는 두 계정이 대화마다 자리를 바꾼다.
전환은 프롬프트 캐시를 버리는 행위라 왕복 자체가 손해다.

기본값은 threshold 15%, hysteresis 10% 다. 즉 **25% 이상 남아야 tier 0** 이고,
한 번 tier 1 로 내려간 계정은 25% 를 회복해야 다시 선호된다.

#### 읽기 없는 계정은 제외가 아니라 tier 1

CCSwitcher 는 읽기 없는 후보를 **부적격**으로 뺀다. 라운드로빈 폴링이라 "샘플 없음" 이
"아직 차례가 아님" 을 뜻하고, 이걸 폴백으로 쓴 탓에 자동 전환이 이미 소진된 계정에
착지한 적이 있기 때문이다.

**우리는 제외하지 않고 tier 1 로 내린다.** 이유가 다르다.

- CCSwitcher 는 선제 전환만 한다. 후보를 빼도 그냥 제자리에 있으면 그만이다
- clfl 은 반응형 경로가 함께 있다. 후보를 풀에서 빼버리면 429 를 맞았을 때 넘어갈 곳이
  사라진다. **가용성을 줄이는 대가가 그쪽보다 크다**

그리고 우리는 등록할 때 검증 요청으로 첫 스냅샷을 채우므로
([05 문서](05-account-registration.md) 3-3절) "읽기 없음" 자체가 드물다.

### 3-4. 선제 전환 가드

반응형 스왑과 선제 전환은 **가드가 달라야 한다.**

| | 반응형 (429/401) | 선제 전환 |
|---|---|---|
| 트리거 | 서버가 거절했다 | 우리가 판단했다 |
| 쿨다운 | **걸지 않는다** | 건다 |
| 재진입 가드 | 불필요 (요청당 `tried` 로 충분) | 필요 |

**반응형에 쿨다운을 걸면 안 된다.** 429 는 그 계정을 지금 쓸 수 없다는 서버의 사실
통보다. 쿨다운 때문에 넘어가지 못하면 요청이 그냥 실패한다.

선제 전환은 우리 판단이므로 틀릴 수 있고, 틀렸을 때 왕복하면 캐시를 반복해서 버린다.

```swift
actor Router {
    private var lastProactiveSwitchAt: Date?
    private var isEvaluatingProactive = false

    private let proactiveCooldown: TimeInterval = 300
}
```

적용 규칙:

- 쿨다운 안이면 선제 강등을 **건너뛴다**. 후보는 priority 순서 그대로 간다
- **수동 전환과 반응형 스왑도 쿨다운을 재시작한다.** 방금 계정이 바뀌었는데 곧바로
  선제 판단이 또 옮기면 사용자가 영문을 모른다
- 평가 중 재진입은 무시한다. 동시 요청이 여럿이므로 실제로 겹친다

### 왜 대화 시작에만 적용하나

선제 전환은 **프롬프트 캐시를 자발적으로 버리는 행위**다. 캐시는 계정/조직 스코프라
계정을 바꾸면 전체 컨텍스트가 cache miss 가 되고 `cache_creation` 으로 다시 청구된다
(cache write 는 1.25배 단가).

대화 중간에 전환하면 남은 여유분의 가치보다 캐시 재생성 비용이 큰 경우가 많다.
대화 시작 시점에는 어차피 캐시가 없으므로 손해가 없다.

### 대화 시작 판정

`X-Claude-Session-Id` 헤더가 **처음 관측된 요청**을 대화 시작으로 본다. 최근 세션 id 를
LRU 집합으로 유지한다.

```swift
protocol ConversationStartDetecting {
    mutating func isStart(sessionID: SessionID?) -> Bool
}
```

**헤더가 없으면 `false` 를 반환한다.** 판정 불가일 때 선제 전환을 하지 않는 쪽이
안전하다. 캐시를 잘못 버리는 것보다 quota 를 조금 더 쓰는 편이 낫다.

> 검증 필요: 데스크톱 앱이 이 헤더를 보내는지, `--resume` 시 세션 id 가 유지되는지
> 실측해야 한다. 안 보내면 선제 전환은 "새 대화" 버튼 같은 명시적 신호가 필요해진다.

### 3-3. 자동 전환에서 빼기

`Account.autoSwitch = false` 인 계정은 선택 후보에서 아예 빠진다. 계정, 토큰,
우선순위 자리, 지금까지의 사용 기록은 전부 그대로 남는다.

**왜 삭제가 아니라 제외인가.** 지우면 토큰을 다시 발급받아야 하고 순서도 다시 잡아야
한다. 잠시 빼두는 것과 없애는 것은 다른 행위다.

쓰는 상황:

- 데이터 이그레스 때문에 enterprise 계정을 자동 전환 대상에서 빼고 싶을 때
- 크레딧을 아끼려고 특정 계정을 예비로 남겨둘 때
- 개인 계정에 업무 트래픽이 가지 않게 하고 싶을 때
- 문제를 좁히려고 한 계정만 잠시 빼고 볼 때

**건강 상태와 다른 축이다.** 제외는 사용자의 의사이고 쿨다운과 인증 실패는 계정의
상태다. 그래서 `Availability` 에 case 를 추가하지 않고 별도 불리언으로 둔다. 제외된
계정이 동시에 쿨다운일 수도 있고, UI 는 두 가지를 함께 보여준다.

```swift
/// 자동 전환 후보인지. 건강 상태와 무관하게 사용자 의사만 본다.
func isAutoEligible(_ a: Account) -> Bool { a.autoSwitch }
```

#### 소진 상황에서도 끌어다 쓰지 않는다

자동 전환 대상이 전부 소진됐는데 제외해 둔 계정에 여유가 있으면, **그래도 쓰지
않는다.** 데이터 이그레스가 걱정돼서 뺀 계정을 마지막 수단이라며 조용히 끌어다 쓰면
사용자가 뺀 이유 자체를 배신하는 것이다.

대신 `.exhausted(unblockable:)` 에 그 계정 목록을 실어 보내서, UI 가 무엇을 켜면
풀리는지 알려주고 사용자가 직접 고르게 한다.

#### 마지막 하나를 뺄 때는 막는다

전부 빼면 모든 요청이 실패한다. 두 겹으로 막는다.

- 설정 창에서 마지막 자동 전환 대상을 끄려 하면 확인을 받는다
- 그래도 0개가 되면 `autoSwitchAllDisabled` 조건이 켜지고 배너와 점검 항목에 뜬다

`autoSwitch` 는 설정이므로 `accounts.json` 에 저장한다. `AccountRuntime` 이 아니다.

---

## 4. 쿨다운 적용

```swift
enum RoutingOutcome: Sendable {
    case success(usage: Usage?, rateLimit: RateLimitSnapshot?)
    case rateLimited(model: ModelID, until: Date, transient: Bool)
    case sessionLimited(until: Date)
    case invalidated
    case passthrough                 // 스왑 대상이 아닌 응답
}
```

적용 규칙:

| outcome | 변경 대상 |
|---|---|
| `success` | `lastUsedAt`, `rateLimit` 갱신. 활성 계정 갱신 |
| `rateLimited(transient: false)` | `modelCooldowns[model] = until` |
| `rateLimited(transient: true)` | `modelCooldowns[model] = now + 5초` |
| `sessionLimited` | `accountCooldownUntil = until` |
| `invalidated` | `invalidatedAt = now` |
| `passthrough` | 변경 없음 |

`until` 계산은 [포팅 02](../porting/02-response-classification.md) 3절의
`resolveResetEpoch` 를 그대로 쓴다. `transient` 판정은 같은 문서 4절.

동시 요청이 같은 계정에 쿨다운을 적용하면 **나중 값으로 덮어쓴다.** 최신 429 가 가장
신선한 `reset_epoch` 를 들고 있기 때문이다.

---

## 5. 조건과 사건

[포팅 README](../porting/README.md) 의 dedupe 논의를 타입으로 옮긴 것.

```swift
/// 지속 조건. 참인 동안 UI 에 계속 보인다. 시간 기반 dedupe 를 두지 않는다.
enum Condition: Hashable, Sendable {
    case crossPlanActive(from: AccountID, to: AccountID)
    case accountInvalid(AccountID)
    case poolExhausted
    /// 자동 전환 대상이 0개다. 모든 요청이 실패한다.
    case autoSwitchAllDisabled
    /// 토큰 만료가 7일 이내. 여러 계정을 비슷한 시기에 등록했다면 함께 만료된다.
    case tokenExpiringSoon(AccountID, daysLeft: Int)
    case proxyDetached          // settings.json 에 우리 값이 없다
}

/// 순간 사건. 타임라인에 append 하고 지우지 않는다.
struct RoutingEvent: Codable, Sendable {
    let at: Date
    let sessionID: SessionID?
    let kind: Kind

    enum Kind: Codable, Sendable {
        case swap(from: AccountID, to: AccountID, trigger: String, crossPlan: Bool)
        case poolExhausted(lastTried: AccountID?)
        case largeRequestSkipped(bytes: Int)
        case accountInvalidated(AccountID)
    }
}
```

표시 규칙:

| 표면 | 대상 | dedupe |
|---|---|---|
| 팝오버 배너 | 현재 참인 `Condition` 전부 | 없음. 조건이 곧 상태다 |
| 계정 카드 뱃지 | 해당 계정의 `Condition` | 없음 |
| 타임라인 | `RoutingEvent` 전부 | 없음 |
| OS 알림 | `Condition` 집합에 **새로 들어올 때** 1회 | 상태 전이가 곧 dedupe |

**dedupe 는 sink 안에 둔다.** 생산자(라우터)는 조건과 사건을 있는 그대로 보고하고,
어떤 표면이 무엇을 언제 보여줄지는 각 sink 가 정한다. claulay 는 dedupe 가 생산자
(`swap.ts`)에 있어서 한 표면이 슬롯을 소모하면 다른 표면이 침묵하는 구조다.

---

## 6. 영속화 분할

```
Keychain (service: "clfl")
  account = <AccountID>, secret = OAuth 토큰

~/Library/Application Support/clfl/
+-- accounts.json      Account 목록 + priority 배열
+-- runtime.json       AccountID -> AccountRuntime 전체
+-- usage.jsonl        요청별 토큰 사용량 (append)
+-- audit.jsonl        RoutingEvent (append)
`-- diagnostic.log     회전 로그
```

### runtime.json 을 영속화하는 이유

clfl 은 상시 실행 앱이지만 로그인, 업데이트, 크래시로 재시작한다. 재시작할 때마다
런타임 상태를 잃으면:

- 소진된 (계정, 모델) 쌍을 다시 프로브해서 429 캐스케이드를 반복한다
- 401 로 무효화한 계정이 되살아나 또 시도한다
- 5시간짜리 세션 쿨다운이 앱 재시작 한 번으로 리셋된다
- UI 게이지가 첫 요청 전까지 비어 있다

claulay 가 `model-cooldowns.json` 을 도입한 이유와 같다. 다만 claulay 는 모델 쿨다운만
남겼는데, 우리는 `AccountRuntime` 전체를 하나의 파일로 남긴다. 파일이 하나면 원자적
쓰기가 단순하다.

쓰기 정책:

- 임시 파일 + rename 으로 원자적 교체, 모드 0600
- 1초 debounce 로 합쳐 쓴다. 요청마다 쓰지 않는다
- 로드 실패는 치명적이지 않다. 빈 런타임으로 시작하고 진단 로그에만 남긴다
- `modelCooldowns` 항목은 7일 지나면 정리한다

### accounts.json

```json
{
  "version": 1,
  "priority": ["team1", "team2", "ent1"],
  "accounts": {
    "team1": { "plan": "team" },
    "ent1":  { "plan": "enterprise", "baseURL": "https://ent.example.com" }
  }
}
```

우선순위는 별도 배열로 둔다. UI 의 드래그 재정렬이 이 배열만 다시 쓰면 되기 때문이다.
`accounts` 에 없는 id 가 `priority` 에 있으면 로드 시 걸러낸다.

### usage.jsonl 스키마

```json
{"ts":"2026-08-01T09:00:00Z","account":"team1","model":"...","session_id":"...",
 "input_tokens":1234,"output_tokens":567,
 "cache_creation_input_tokens":0,"cache_read_input_tokens":0}
```

캐시 두 필드를 반드시 남긴다. `audit.jsonl` 의 스왑 시각과 조인하면 스왑이 유발한 캐시
재생성 비용을 정확히 뽑을 수 있고, 선제 전환 임계값을 실측으로 정하는 유일한 근거다.

---

## 7. 메뉴바 표시 코드

메뉴바는 폭이 귀하다. 계정 이름을 그대로 쓰면 시계와 다른 메뉴 항목을 밀어낸다.
그래서 계정마다 짧은 코드를 만들어 메뉴바에서만 쓴다. 팝오버와 설정 창은 원래 이름을
그대로 쓴다.

### 규칙

- 이름에 `team` 이 들어간 계정 (대소문자 무시): 그들끼리 **알파벳순으로 정렬해**
  `T1`, `T2`, ... 를 준다. 번호는 이름 안의 숫자가 아니라 **정렬 순서**에서 나온다
- 나머지 계정: 이름 **앞 2글자를 대문자로**
- 앞 2글자가 겹치면 첫 글자 + 정렬 순서로 바꾼다

```swift
/// 메뉴바 전용 축약 코드. 순수 함수이므로 계정 집합이 같으면 결과가 항상 같다.
func shortCodes(for ids: [AccountID]) -> [AccountID: String] {
    var out: [AccountID: String] = [:]

    let isTeam = { (id: AccountID) in id.lowercased().contains("team") }
    let teams  = ids.filter(isTeam).sorted()
    let others = ids.filter { !isTeam($0) }.sorted()

    for (i, id) in teams.enumerated() { out[id] = "T\(i + 1)" }

    // 앞 2글자로 묶고, 겹치는 묶음만 첫 글자 + 순번으로 대체한다.
    var byPrefix: [String: [AccountID]] = [:]
    for id in others {
        byPrefix[id.prefix(2).uppercased(), default: []].append(id)
    }
    for (prefix, group) in byPrefix {
        if group.count == 1 {
            out[group[0]] = prefix
        } else {
            let head = prefix.prefix(1)
            for (i, id) in group.enumerated() { out[id] = "\(head)\(i + 1)" }
        }
    }
    return out
}
```

`others` 가 이미 정렬돼 있으므로 묶음 안의 순번도 결정적이다. `byPrefix` 의 순회 순서는
보장되지 않지만 묶음끼리는 서로 영향을 주지 않는다.

### 예시

| 계정 이름 | 코드 | 근거 |
|---|---|---|
| `team1` | `T1` | team 포함. 알파벳순 1번째 |
| `team2` | `T2` | team 포함. 알파벳순 2번째 |
| `team3` | `T3` | team 포함. 알파벳순 3번째 |
| `ent1` | `EN` | 앞 2글자 |
| `personal` | `PE` | 앞 2글자 |
| `ent1`, `ent2` 가 함께 있으면 | `E1`, `E2` | 앞 2글자가 겹쳐 순번으로 대체 |

### 두 가지 주의

**재번호 문제.** 번호가 정렬 순서에서 나오므로 계정을 추가하면 기존 코드가 바뀐다.
`team1`, `team3` 이 `T1`, `T2` 였다가 `team2` 를 추가하면 `team3` 이 `T3` 으로 밀린다.
사용자가 외운 코드가 조용히 바뀌는 셈이다.

대안은 이름 안의 숫자를 그대로 쓰는 것(`team3` -> `T3`)인데, 숫자가 없는 이름
(`team-alpha`)을 다룰 수 없고 두 자리 숫자면 코드가 길어진다. 현재 규칙을 쓰되
**설정 창의 계정 목록에 코드를 함께 표시**해서 확인할 수 있게 한다.

**team 계정 10개 이상.** `T10` 은 3글자가 된다. 메뉴바 폭이 조금 늘어날 뿐 동작에는
문제가 없다.

### 메뉴바 표시 모드

폭과 정보량은 맞바꿀 수밖에 없다. 노브를 여러 개 두는 대신 **미리 맞춰둔 셋 중 하나**를
고르게 한다.

```swift
public enum MenuBarDisplayMode: String, Codable, Sendable {
    /// 기본값. 코드 + 숫자 두 줄 + 도트 블록 세 줄. 약 122pt
    case standard
    /// 코드 + 블록. 숫자를 뺀다. 약 103pt
    case dotsOnly
    /// 코드 + 숫자 두 줄. 직전 조직이 옆에 들어온다. 약 87pt
    case numbers
    /// 코드 하나. 약 46pt
    case codeOnly
}
```

| 모드 | 코드 | 숫자 | 도트 블록 | 직전 조직 | 폭 |
|---|---|---|---|---|---|
| `standard` (기본) | O | 5시간, 주간 | 세 창 | X | 122pt |
| `dotsOnly` | O | X | 세 창 | X | 103pt |
| `numbers` | O | 5시간, 주간 | X | **O** | 87pt |
| `codeOnly` | O | X | X | X | 46pt |

### 왜 숫자와 블록을 함께 두나

메뉴바 높이 안에 들어가는 숫자는 **두 줄이 한계**다(8pt 두 줄 = 16pt, 항목 높이 20pt).
그런데 조직을 묶는 창은 셋이다.

- 숫자만 두면 셋째 창이 안 보인다
- 블록만 두면 정확한 값을 못 읽는다

그래서 기본은 둘을 함께 둔다. 숫자는 자주 보는 두 창을 정확히, 블록은 셋을 한눈에.

```
T2 38%  [::::::::......]   <- 5시간 38%
   26%  [::::.........]    <- 주간 26%
        [:::::::::::..]    <- 모델별 주간 74%
```

**이 조합이 실제로 값을 하는 경우**가 전환 직후다. 숫자로는 53% 와 41% 라 여유로워
보이는데 블록의 맨 아랫줄이 비어 있다. 모델별 주간이 바닥나서 넘어온 것이고, 그 사실은
블록에만 있다.

직전 조직은 `numbers` 모드에서만 보인다. 다른 모드에는 자리가 없고, 전환이 일어난 사실은
코드가 바뀌는 것으로 드러난다.

### 막대는 도트 격자로 그린다

솔리드 막대 대신 **도트 텍스처**를 쓴다. 빈 칸과 채운 칸이 같은 격자 위에 놓이고
채운 쪽만 색이 진해지는 형태다.

```
채움 88%   [::::::::::::::::::::......]
채움  8%   [::........................]
```

블록 하나는 3pt 짜리 줄 셋이 쌓인 52x9pt 다. **그 세 줄에 세 창을 하나씩 나눠 준다.**

- 격자 간격 3pt 짜리 세 줄이 막대 하나(9pt)를 이룬다. 빈 칸과 채운 칸이 **같은
  background-size 와 position** 을 써야 한 줄로 읽힌다. 채움 층을 트랙의 `left: 0` 에
  붙이고 `background-position: 0 0` 으로 맞춘다
- 작은 크기에서 솔리드 막대보다 눈금이 읽힌다. 4pt 짜리 실선은 색만 보이지만
  도트는 남은 칸 수가 보인다
- **NSProgressIndicator 의 기본 모양은 아니다.** 의도적인 이탈이다

세 창은 서로 독립적으로 바닥나므로 **색도 창마다 따로 붙는다.** 숫자와 줄이 같은 창을
가리키면 둘 다 물들고, 셋째 창은 숫자가 없으므로 줄만 물든다.

잔여가 0% 여도 채움에 `min-width` 를 줘서 한 점은 남긴다. 빈 자리와 소진을 구별해야
한다.

설정이므로 `UserDefaults` 에 둔다. 라우팅과 무관하다.

### 최근 사용한 다른 계정

메뉴바는 활성 계정 옆에 **직전에 쓰던 계정** 하나를 함께 보여준다.

```swift
/// 활성 계정을 뺀 나머지 중 가장 최근에 쓴 계정.
func mostRecentOther(
    runtime: [AccountID: AccountRuntime], activeID: AccountID?
) -> AccountID? {
    runtime
        .filter { $0.key != activeID && $0.value.lastUsedAt != nil }
        .max { ($0.value.lastUsedAt ?? .distantPast) < ($1.value.lastUsedAt ?? .distantPast) }?
        .key
}
```

**전환 직후에는 여기 잡히는 것이 방금 한도에 걸려 떠나온 계정이다.** 그래서 이 자리는
드문 경우를 위한 장식이 아니라 전환 후 가장 궁금한 정보 하나를 담는다. 원래 계정으로
언제 돌아갈 수 있는지가 그것이다.

### 표시 형식

활성 계정과 직전 계정 모두 같은 형식을 쓴다.

```
T1 56%   T2 88%          <- 실제로는 코드와 숫자가 붙는다
    9%      69%
```

- 숫자는 **남은 양**이다. 쓴 양이 아니다. 클수록 좋다
- 코드 뒤에 숫자를 **두 줄**로 쌓는다. 위가 5시간 잔여, 아래가 7일 잔여
- 코드와 숫자 사이에 공백을 두지 않는다. 두 줄로 쌓인 형태가 이미 구분이 된다
- 두 계정 사이에 분리선을 긋지 않는다. 여백과 투명도만으로 가른다
- 직전 계정은 투명도를 낮춰 확실히 뒤로 물린다

**잔여로 표시하는 이유.** 메뉴바를 흘깃 보는 목적이 "아직 돌려도 되나"를 확인하는
것이므로, 남은 쪽이 곧바로 답이 되는 숫자다.

**두 줄인 이유.** 전환은 5시간과 7일 중 어느 쪽이 먼저 바닥나느냐에 따라 일어난다.
하나만 보여주면 왜 넘어왔는지가 절반 가려진다. 5시간이 53% 나 남았는데 7일이 0% 라서
넘어온 경우, 5시간만 보면 이유를 알 수 없다.

### 색

색은 계정이 아니라 **줄마다 따로** 붙는다. 두 창은 서로 독립적으로 바닥난다.

| 남은 양 | 색 | 뜻 |
|---|---|---|
| 50% 이상 | 녹색 | 여유. 계속 써도 되고 넘어올 곳으로도 좋다 |
| 15% 이상 50% 미만 | 기본색 | 정상 범위. 굳이 눈길을 끌지 않는다 |
| 5% 이상 15% 미만 | 노랑 | 선제 전환 임계값 아래. 새 대화는 다른 계정으로 간다 |
| 5% 미만 | 빨강 | 사실상 소진. 곧 강제로 넘어간다 |

경계값이 임의가 아니다. **노랑이 시작되는 15% 는 선제 전환 임계값과 같은 값**이라,
노랑은 곧 "이 계정은 새 대화 후보에서 이미 밀려났다" 는 뜻이 된다. 빨강 5% 는 대화
도중에 강제로 넘어가기 직전 구간이다. 임계값을 설정에서 바꾸면 노랑 경계도 함께
움직인다.

```swift
enum HeadroomBand { case ample, normal, low, empty }

/// remaining 은 0.0 ~ 1.0 의 잔여 비율.
/// lowThreshold 는 선제 전환 임계값과 같은 값을 넘겨받는다 (기본 0.15).
func band(remaining: Double, lowThreshold: Double = 0.15) -> HeadroomBand {
    if remaining < 0.05        { return .empty }
    if remaining < lowThreshold { return .low }
    if remaining < 0.50        { return .normal }
    return .ample
}
```

### 상태별 처리

| 상태 | 표시 |
|---|---|
| 대기, 사용 중 | 5시간과 7일 잔여 두 줄 |
| 쿨다운 | 두 줄 유지. 바닥난 쪽이 빨강 0% 로 나오므로 그 자체가 이유가 된다 |
| 인증 실패 | 숫자를 빼고 코드만 흐리게. 시간으로 풀리지 않으므로 숫자가 무의미 |

기록된 계정이 하나도 없으면 (첫 실행) 이 자리는 비운다.

메뉴바 높이는 24pt 안팎이다. 두 줄이 들어가려면 숫자가 8pt 급으로 작아지므로 등폭
숫자(`tabular-nums`)를 써서 자리가 흔들리지 않게 한다.

> `RateLimitSnapshot` 은 응답 헤더에서 온 **사용률**을 담는다(2절). 잔여는
> `1 - usedRatio` 로 표시 직전에 뒤집는다. 저장 형식을 바꾸지 않는 이유는 헤더가 주는
> 값이 사용률이고, 선제 강등 로직(3절)도 사용률 기준으로 쓰여 있기 때문이다.
> **뒤집기는 표시 계층에서 한 번만 한다.**

---

## 8. claulay 에서 가져오지 않는 것

| claulay | 왜 안 가져오나 |
|---|---|
| `config.yaml` | YAML 의존을 추가할 이유가 없다. JSON 으로 충분 |
| `vault.enc` + PBKDF2 | Keychain 이 대체. passphrase 설정 단계가 통째로 사라진다 |
| `state.json` 의 epoch 필드 | 상태를 파생시키므로 불필요 |
| `cross-plan-notice.json` | 조건 표시로 대체. 5절 참고 |
| `stale-daemon-notice.json` | daemon 이 없다 |
| `session-<id>.json` 스냅샷 | statusline 전용이었다. 메뉴바가 직접 상태를 본다 |
