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

struct RateLimitSnapshot: Codable, Sendable {
    var fiveHourUsedRatio: Double?      // 0.0 ~ 1.0
    var fiveHourResetAt: Date?
    var sevenDayUsedRatio: Double?
    var sevenDayResetAt: Date?
    var observedAt: Date
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
    /// 전부 invalid. 시간이 지나도 회복되지 않는다.
    case exhausted
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
    let proactiveThreshold: Double      // 예: 0.85
}

func select(_ input: SelectionInput) -> SelectionResult
```

순서:

1. 후보 = `priority` 순서에서 `tried` 를 뺀 것
2. `invalid` 제외
3. `cooling(account)` 제외
4. `cooling(model)` 제외 (요청 모델과 일치할 때만)
5. **선제 강등** (아래 참고). 제외가 아니라 후순위로 민다
6. 남은 것 중 최상위 반환
7. 아무것도 없으면
   - 시간으로 회복 가능한 계정이 있으면 -> `.wait(가장 이른 해제 시각)`
   - 전부 invalid 면 -> `.exhausted`

7번의 구분이 중요하다. claulay 는 이 구분이 없어서 일시 과부하와 진짜 소진이 같은 경로로
흘렀고, 시작 시 풀 전체가 60초 암전되는 증상을 낳았다
([포팅 02](../porting/02-response-classification.md) 4절).

### 선제 강등

quota 가 차기 전에 미리 전환하되, **제외가 아니라 2단계 정렬**로 처리한다.

```
tier 0 : 5h 사용률 <= 임계값        (선호)
tier 1 : 5h 사용률 >  임계값        (tier 0 이 비었을 때만)

각 tier 안에서는 priority 순서 유지
```

제외가 아니라 강등인 이유: 전 계정이 임계값을 넘었을 때 가용 계정이 0이 되면 안 된다.
강등은 가용성을 절대 줄이지 않는다.

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

## 7. claulay 에서 가져오지 않는 것

| claulay | 왜 안 가져오나 |
|---|---|
| `config.yaml` | YAML 의존을 추가할 이유가 없다. JSON 으로 충분 |
| `vault.enc` + PBKDF2 | Keychain 이 대체. passphrase 설정 단계가 통째로 사라진다 |
| `state.json` 의 epoch 필드 | 상태를 파생시키므로 불필요 |
| `cross-plan-notice.json` | 조건 표시로 대체. 5절 참고 |
| `stale-daemon-notice.json` | daemon 이 없다 |
| `session-<id>.json` 스냅샷 | statusline 전용이었다. 메뉴바가 직접 상태를 본다 |
