import Foundation
import ClflCore

/// 응답 헤더에 편승해 사용량을 읽는다.
///
/// 요청을 하나 더 보내지 않고 얻는 유일한 관측이다. Usage API 는 `user:profile`
/// 스코프를 요구하는데 setup-token 에는 없다. 그런 조직에서는 이것이 전부다.
///
/// 이름과 의미는 실제 응답에서 옮겼다. 서버는 **잔여가 아니라 사용률**을 주고
/// 단위는 백분율이 아니라 0..1 비율이다.
///
/// ```
/// anthropic-ratelimit-unified-5h-utilization: 0.16
/// anthropic-ratelimit-unified-5h-reset: 1785600000
/// anthropic-ratelimit-unified-7d-utilization: 0.11
/// anthropic-ratelimit-unified-representative-claim: five_hour
/// ```
/// docs/design/02-domain-model.md 2절
public enum RateLimitHeaderNames {
    public static let fiveHourUtilization = "anthropic-ratelimit-unified-5h-utilization"
    public static let fiveHourReset       = "anthropic-ratelimit-unified-5h-reset"
    public static let sevenDayUtilization = "anthropic-ratelimit-unified-7d-utilization"
    public static let sevenDayReset       = "anthropic-ratelimit-unified-7d-reset"
    /// 서버가 스스로 지목하는 구속 창. 우리 계산과 대조할 수 있다.
    public static let representativeClaim = "anthropic-ratelimit-unified-representative-claim"
}

/// 헤더 하나도 없으면 nil 이다. 빈 스냅샷을 만들어 저장하면 이전에 읽어둔 값을
/// 지워버린다. 관측하지 못한 것과 0으로 관측한 것은 다르다.
///
/// 일시 과부하 429 에는 이 헤더가 하나도 오지 않는다. 그때 nil 을 내는 것이
/// 맞다. 용량 문제를 사용량 0 으로 기록하면 안 된다.
///
/// 모델별 주간은 절대 채우지 않는다. 헤더에 그 정보가 없다. Usage API 만 안다.
public func rateLimitSnapshot(from headers: HeaderBag, now: Date) -> RateLimitSnapshot? {
    let fiveHour = window(headers,
                          utilization: RateLimitHeaderNames.fiveHourUtilization,
                          reset: RateLimitHeaderNames.fiveHourReset)
    let sevenDay = window(headers,
                          utilization: RateLimitHeaderNames.sevenDayUtilization,
                          reset: RateLimitHeaderNames.sevenDayReset)
    guard fiveHour != nil || sevenDay != nil else { return nil }

    return RateLimitSnapshot(fiveHour: fiveHour, sevenDayAll: sevenDay,
                             observedAt: now, source: .headers)
}

/// 서버가 주는 사용률을 그대로 쓴다. 잔여는 Window 가 파생시킨다.
private func window(_ headers: HeaderBag, utilization: String, reset: String) -> Window? {
    guard let raw = headers[utilization], let used = Double(raw) else { return nil }
    return Window(usedRatio: min(1, max(0, used)), resetsAt: epochDate(headers[reset]))
}

/// epoch 초. 값이 없거나 읽히지 않으면 nil 이고, 그 창은 만료 시각을 모른다.
private func epochDate(_ raw: String?) -> Date? {
    guard let raw, let seconds = Double(raw), seconds >= Double(epochHeuristicMin) else { return nil }
    return Date(timeIntervalSince1970: seconds)
}
