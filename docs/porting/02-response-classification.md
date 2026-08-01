# 02. 응답 분류와 쿨다운

**출처:** `claulay/src/proxy/interceptor.ts` (202 LOC), `interceptor.test.ts`,
`swap.ts`의 `isRetryableRateLimit`

Anthropic 응답 하나를 보고 **스왑할지 통과시킬지** 결정하는 유일한 지점.
그리고 스왑할 경우 해당 계정을 **언제까지 쿨다운**할지 계산한다.

---

## 1. 타입

```swift
enum SwapTrigger: Equatable {
    case rateLimit(accountID: String, resetEpoch: Int, sessionID: String)
    case sessionLimit(accountID: String, resetEpoch: Int, sessionID: String)
    case authentication(accountID: String, sessionID: String)

    /// 분류기는 절대 생성하지 않음 - 스왑 루프의 종단 분기 전용.
    /// 같은 enum에 두는 이유는 소비자가 하나의 exhaustive switch를 쓰게 하려고.
    case poolExhausted(accountID: String?, sessionID: String)
}

struct ClassifyInput {
    let status: Int
    let headers: HeaderBag
    let body: Data?                 // 비스트리밍 (firstSSEEvent와 상호배타)
    let firstSSEEvent: SSEEvent?    // 스트리밍: peek한 첫 이벤트
    let accountID: String
    let sessionID: String
    let now: Int                    // epoch seconds - retry-after 계산 기준점
}
```

`rateLimit`과 `sessionLimit`의 차이:

| 트리거 | 범위 | 의미 |
|---|---|---|
| `rate_limit_error` | **모델 단위** | 특정 모델의 한도(예: Fable 주간). 같은 계정의 다른 모델은 계속 사용 가능 |
| `session_limit_error` | **계정 전체** | 5시간 세션 한도. 계정 전체 쿨다운 |

claulay는 이 구분을 위해 `(account, model)` 쌍 단위 쿨다운 맵을 별도로 관리한다
(`state/model-cooldowns.ts`). Anthropic의 429 응답은 계정 전체 단위 윈도우만 노출하고
모델을 알려주지 않으므로, 스코프 기준은 **요청한 모델**이다.

---

## 2. 분류 본체

```swift
func classifyResponse(_ input: ClassifyInput) -> SwapTrigger? {
    guard let errorType = extractErrorType(input) else { return nil }   // 파싱 실패 = 통과
    let isStreamingError = input.firstSSEEvent?.event == "error"

    switch errorType {
    case "rate_limit_error", "session_limit_error":
        guard input.status == 429 || isStreamingError else { return nil }
        let reset = resolveResetEpoch(input.headers, now: input.now)
        return errorType == "rate_limit_error"
            ? .rateLimit(accountID: input.accountID, resetEpoch: reset, sessionID: input.sessionID)
            : .sessionLimit(accountID: input.accountID, resetEpoch: reset, sessionID: input.sessionID)

    case "authentication_error":
        guard input.status == 401 || isStreamingError else { return nil }
        return .authentication(accountID: input.accountID, sessionID: input.sessionID)

    default:
        return nil
    }
}
```

### `isStreamingError` 분기를 빠뜨리기 쉽다

HTTP `200`으로 시작한 SSE 스트림의 **첫 프레임이 `event: error`인 경우가 실제로 있다.**
status만 보면 이걸 통째로 놓치고 사용자에게 에러가 그대로 노출된다.

이 때문에 스트리밍 응답도 첫 프레임을 peek해서 분류해야 하며, 그것이
[03. SSE peek](03-sse-streaming.md)의 존재 이유다.

### 에러 타입 추출

```swift
func extractErrorType(_ input: ClassifyInput) -> String? {
    let raw: Data? = input.firstSSEEvent.map { Data($0.data.utf8) } ?? input.body
    guard let raw,
          let obj   = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let error = obj["error"] as? [String: Any],
          let type  = error["type"] as? String
    else { return nil }        // 어떤 실패든 nil -> passthrough (방어적 계약)
    return type
}
```

JSON이 아니거나, `error` 객체가 없거나, `type`이 문자열이 아니면 전부 `nil` -> 통과.
Anthropic 형태의 에러가 아닌 응답을 건드리지 않기 위한 방어적 계약이다.

---

## 3. 쿨다운 시각 해석 - 2순위 함정

```swift
private let defaultCooldownSeconds = 60
private let epochHeuristicMin = 1_000_000_000        // 2001-09-09. 이보다 작으면 epoch 아님

func resolveResetEpoch(_ headers: HeaderBag, now: Int) -> Int {
    // 1. retry-after (초 단위 delta) - Anthropic의 권위 있는 "다음 재시도" 신호.
    //    실제로 이 요청을 막고 있는 윈도우가 무엇이든 그걸 반영한다.
    if let raw = headers["retry-after"], let n = Int(raw), n >= 0 {
        return now + n
    }

    // 2. 없으면: 아직 도래하지 않은 anthropic-ratelimit-*-reset 중 "가장 가까운" 것
    var nearest: Int?
    for (k, v) in headers.storage {
        guard k.hasPrefix("anthropic-ratelimit-"), k.hasSuffix("-reset") else { continue }
        guard let epoch = Int(v), epoch >= epochHeuristicMin, epoch > now else { continue }
        if nearest == nil || epoch < nearest! { nearest = epoch }
    }
    if let nearest { return nearest }

    // 3. 그래도 없으면 60초
    return now + defaultCooldownSeconds
}
```

### `max`가 아니라 `min`(nearest)인 이유

Anthropic은 429에 **추적 중인 모든 윈도우**의 reset을 함께 실어 보낸다(5h, 7d, ...).
5h만 걸린 상황에서도 7d reset은 수십 시간~일주일 뒤다.

`max`를 쓰면 실제 쿨다운이 5시간인데 **계정을 37시간 이상 퇴장**시킨다.

가장 가까운 reset = 어떤 한도든 처음 풀리는 시각 = 재시도가 성공할 수 있는 가장 이른 순간.
틀렸으면 다음 429가 새 `reset_epoch`로 자기 교정한다.

### 두 개의 가드

- `epoch > now` - 이미 지난 reset 헤더는 건너뛴다
- `epoch >= epochHeuristicMin` - 서버가 delta-seconds를 reset 헤더에 넣는 경우를 거른다

### Swift 파싱 엄격성 차이

`Int("120s")`는 `nil`이지만 JS `parseInt("120s", 10)`은 `120`이다. Swift 쪽이 더 엄격해
안전하지만, 값이 파싱되지 않으면 2. -> 3.으로 폴백한다는 점을 인지할 것.

HTTP 명세상 `retry-after`는 delta-seconds 또는 HTTP-date인데, 원본도 Swift도 HTTP-date는
파싱하지 않고 폴백한다.

---

## 4. transient overload - 보조 규칙

**출처:** `swap.ts`의 `isRetryableRateLimit` (`swap.ts:388-413`)

분류기가 `rateLimit`을 냈다고 전부 같은 쿨다운을 주면 안 된다.

```swift
private let transientCooldownSeconds = 5

/// 진짜 quota 소진과 일시적 과부하 429를 구분. 두 조건 모두 만족해야 transient.
func isTransientOverload(headers: HeaderBag, trigger: SwapTrigger) -> Bool {
    // sessionLimit(공유 5h 예산)과 authentication은 절대 transient가 아니다.
    guard case .rateLimit = trigger else { return false }

    // 1. Anthropic 자신의 "재시도해라" 신호
    guard headers["x-should-retry"] == "true" else { return false }

    // 2. anthropic-ratelimit-* 윈도우 헤더가 "없어야" 한다.
    //    진짜 5h/7d/overage 거절은 항상 unified 윈도우 헤더를 동반한다
    //    (resolveResetEpoch가 실제 reset을 거기서 얻는다).
    //    "부재"를 요구해야 진짜 한도를 transient로 오분류하지 않는다.
    return !headers.storage.keys.contains { $0.hasPrefix("anthropic-ratelimit-") }
}
```

### 없으면 무슨 일이 생기나

claulay README 트러블슈팅에 기록된 실제 증상:

```
시작 시 요청이 우선순위 체인을 훑음
  -> 건강한 계정마다 일시 과부하 429를 연쇄로 맞음
  -> 각 계정을 60초 벤치
  -> 풀 전체가 ~60초 동시 암전
  -> 503 no account available
```

정작 `status`는 정상으로 보여서 진단이 어렵다. 계정은 실제로 소진되지 않았다.

### 짝이 되는 grace 대기

풀이 순간 비었을 때 즉시 503을 내지 않고, 가장 이른 쿨다운 해제까지 기다렸다가 다시
훑는 예산이 필요하다. claulay는 `CLAULAY_POOL_GRACE_SECONDS`(기본 15초)로 노출한다.

진짜 소진(5h/7d/overage - reset이 먼 미래)은 이 예산을 초과하므로 영향 없이 즉시 fast-fail 된다.

---

## 5. 통과시켜야 하는 케이스

| 응답 | 판정 | 왜 |
|---|---|---|
| `200` 정상 | 통과 | - |
| `529 overloaded_error` | **통과** | Anthropic 측 과부하. 계정 바꿔도 소용없음 |
| `500 api_error` | **통과** | 위와 동일 |
| `429` + 알 수 없는 `error.type` | **통과** | 스왑 집합에 없는 타입은 건드리지 않음 |
| `401` + 인증이 아닌 body | **통과** | status만으로 판단 금지 |
| 파싱 불가 body | **통과** | 방어적 기본값 |
| 네트워크 오류 | **통과** | 분류기에 도달하지 않음 |

---

## 6. 스왑 루프 뼈대

**출처:** `swap.ts`의 `runSwapLoop` 계약 (`swap.ts:60-88`)

```
1. 클라이언트 body를 전량 버퍼링 (<= maxRetryBodyBytes)
2. selectAccount() - 우선순위 최상위 가용 계정
3. 업스트림 시도
4. classifyResponse:
     nil       -> 바이트를 그대로 통과, 종료
     트리거 있음 -> 런타임 상태 변경(쿨다운/무효화) + 감사 로그 + 2번으로 루프
5. 시도 횟수를 priority.count로 제한
6. 체인이 소진되면: 마지막 실패 응답을 클라이언트에 원문 그대로 재생하고
   세션당 pool_exhausted 감사 항목 1건 기록
```

### 왜 별도 루프인가

- 시도가 종단(terminal)이라고 확정되기 전에는 **클라이언트에 한 바이트도 쓸 수 없다**
- 진행 중인 시도를 버리고 계정을 바꿀 수 있어야 한다

이 두 제약이 [03. SSE peek](03-sse-streaming.md)의 전체 설계를 결정한다.

### body 버퍼 상한

```swift
let defaultMaxRetryBodyBytes = 8 * 1024 * 1024   // 8 MiB
```

이 값을 넘으면 버퍼링을 포기하고 그냥 스트리밍으로 흘려보내며, 그 요청은 재전송할 원본이
없어 **스왑이 스킵**된다.

순수 텍스트 1M 컨텍스트는 4~5MB 정도라 여유가 있지만, **base64 이미지, PDF 첨부**가
body를 크게 부풀린다. 스크린샷 몇 장 붙인 턴에서 429가 뜨면 스왑이 안 되고 에러가
그대로 노출된다. 설정으로 노출할 것.

---

## 7. 스왑의 실제 비용

컨텍스트를 "이관"하는 코드는 없다. Anthropic Messages API는 stateless이고, 매 요청이
전체 대화 이력을 `messages[]`에 담아 통째로 보낸다. 스왑은 **같은 바이트를 다른
Authorization으로 재전송**하는 것이다.

그래서 다음이 따라온다:

1. **cross-plan 데이터 이그레스** - team 계정에서 하던 대화 전문이 enterprise 계정의
   로깅, 보존 정책 아래로 들어간다. 사용자 고지가 필요한 이유.
2. **prompt cache 전량 무효화** - 캐시는 계정/조직 스코프다. 스왑하면 새 계정에서
   전부 cache miss가 되고 컨텍스트 전체를 `cache_creation`으로 다시 쓴다
   (cache write는 1.25배 단가). 긴 대화일수록 손해가 크다.
3. 429로 죽은 첫 시도 자체는 과금되지 않는다.

`usage.jsonl`이 `cache_creation_input_tokens` / `cache_read_input_tokens`를 계정별로
기록하므로, `audit.jsonl`의 스왑 시점과 조인하면 **"스왑 때문에 재생성된 캐시 토큰"**을
정확히 뽑을 수 있다. 우선순위 체인 설계와 선제 전환 임계값의 유일한 실증 데이터다.

### 선제 전환 설계 노트

quota가 차기 전에 미리 전환하려면 잔여량을 알아야 하는데, 5h/7d 잔여는
`anthropic-ratelimit-unified-*` **응답 헤더**에만 있다 -> **프록시를 경유해야만 보인다.**
(OAuth Usage API는 `user:profile` 스코프가 필요한데 `setup-token`은 inference-only라 403.)

`selectAccount`에 조건을 추가하는 형태가 된다:

```
5h 사용률 > 임계값 -> 쿨다운은 아니지만 선호도 강등 -> 다음 계정
```

단, **선제 전환은 프롬프트 캐시를 자발적으로 버리는 행위**다. 남은 여유분의 가치보다
캐시 재생성 비용이 크면 손해다. 그래서 임계값은 대화 도중이 아니라 **새 대화 시작
시점에만** 적용해야 한다.

---

## 8. 테스트 케이스

`interceptor.test.ts`에서 그대로 옮길 것.

### 429 `rate_limit_error`
- `retry-after` 헤더에서 `reset_epoch`를 만든다
- **`retry-after`를 `anthropic-ratelimit-*-reset`보다 우선한다 (weekly-reset 과잉 처벌 회피)**
- `retry-after`가 없으면 **가장 가까운** `anthropic-ratelimit-*-reset`으로 폴백한다
- reset 헤더가 전혀 없으면 `now + 60s`

### 429 `session_limit_error`
- session-limit 응답에 대해 `session_limit_error`를 낸다

### 401 `authentication_error`
- 인증 body를 가진 401에 대해 `authentication_error`를 낸다

### 통과 분기
- `529 overloaded_error` -> `nil`
- `500 api_error` -> `nil`
- `200` 성공 -> `nil`
- 스왑 집합에 없는 `error.type`의 429 -> `nil`
- 인증이 아닌 body의 401 -> `nil`
- 파싱 불가 body -> `nil` (방어적)

### `resolveResetEpoch` 단위
- 헤더가 없으면 `now + 60`
- `retry-after`(초 delta)를 존중한다
- `retry-after`를 우선하고 뒤의 reset 헤더들을 무시한다
- `retry-after`가 없으면 **가장 가까운 미래 reset**을 고른다
- **이미 지난 epoch의 reset 헤더는 건너뛴다**
- **10^9 미만 값은 무시한다 (epoch가 아니라는 휴리스틱)**

### 스트리밍 첫 SSE 이벤트
- **`event: error`로 시작하는 `200` 스트림을 첫 SSE 이벤트 body로 분류한다**
- 첫 SSE 이벤트가 `message_start`(정상 스트림)이면 `nil`
