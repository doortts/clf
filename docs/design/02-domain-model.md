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

    /// 토큰 등록 시각. setup-token 이 주는 토큰은 1년짜리라 만료를 미리 알려야 한다.
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
    let proactiveThreshold: Double      // 잔여 기준. 예: 0.15
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

```
tier 0 : 5h 잔여 >= 임계값        (선호)
tier 1 : 5h 잔여 <  임계값        (tier 0 이 비었을 때만)

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
