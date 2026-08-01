import Foundation
import ClflCore

/// 응답 헤더에 편승해 사용량을 읽는다.
///
/// 요청을 하나 더 보내지 않고 얻는 유일한 관측이다. Usage API 를 부를 수 없는
/// setup-token 조직에서는 이것이 전부다.
/// docs/design/02-domain-model.md 2절
public enum RateLimitHeaderNames {
    public static let fiveHourRemaining = "anthropic-ratelimit-unified-5h-remaining"
    public static let fiveHourReset     = "anthropic-ratelimit-unified-5h-reset"
    public static let sevenDayRemaining = "anthropic-ratelimit-unified-7d-remaining"
    public static let sevenDayReset     = "anthropic-ratelimit-unified-7d-reset"
}

/// 헤더 하나도 없으면 nil 이다. 빈 스냅샷을 만들어 저장하면 이전에 읽어둔 값을
/// 지워버린다. 관측하지 못한 것과 0으로 관측한 것은 다르다.
///
/// 모델별 주간은 절대 채우지 않는다. 헤더에 그 정보가 없다. Usage API 만 안다.
public func rateLimitSnapshot(from headers: HeaderBag, now: Date) -> RateLimitSnapshot? {
    let fiveHour = window(headers,
                          remaining: RateLimitHeaderNames.fiveHourRemaining,
                          reset: RateLimitHeaderNames.fiveHourReset)
    let sevenDay = window(headers,
                          remaining: RateLimitHeaderNames.sevenDayRemaining,
                          reset: RateLimitHeaderNames.sevenDayReset)
    guard fiveHour != nil || sevenDay != nil else { return nil }

    return RateLimitSnapshot(fiveHour: fiveHour, sevenDayAll: sevenDay,
                             observedAt: now, source: .headers)
}

/// 서버는 남은 백분율을 준다. 우리는 사용률로 들고 있으므로 뒤집는다.
private func window(_ headers: HeaderBag, remaining: String, reset: String) -> Window? {
    guard let raw = headers[remaining], let percent = Double(raw) else { return nil }
    let clamped = min(100, max(0, percent))
    return Window(usedRatio: 1 - clamped / 100, resetsAt: epochDate(headers[reset]))
}

/// epoch 초. 값이 없거나 읽히지 않으면 nil 이고, 그 창은 만료 시각을 모른다.
private func epochDate(_ raw: String?) -> Date? {
    guard let raw, let seconds = Double(raw), seconds >= Double(epochHeuristicMin) else { return nil }
    return Date(timeIntervalSince1970: seconds)
}
