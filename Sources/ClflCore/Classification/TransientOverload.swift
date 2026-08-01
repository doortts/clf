/// 진짜 quota 소진과 일시적 과부하 429 를 구분한다.
/// docs/porting/02-response-classification.md 4절
///
/// 두 조건을 **모두** 만족해야 transient 다.
///   1. x-should-retry: true  (Anthropic 자신의 재시도 신호)
///   2. anthropic-ratelimit-* 창 헤더가 **없다**
///
/// 진짜 5h/7d/overage 거절은 항상 unified 창 헤더를 동반하므로, 부재를 요구해야
/// 진짜 한도를 transient 로 오분류하지 않는다.
///
/// 이 구분이 없으면 시작 시 건강한 조직마다 과부하 429 를 연쇄로 맞고 각각 60초
/// 벤치되어 풀 전체가 암전된다.
public func isTransientOverload(headers: HeaderBag, trigger: SwapTrigger) -> Bool {
    _ = (headers, trigger)
    fatalError("TODO")
}

public let transientCooldownSeconds = 5
