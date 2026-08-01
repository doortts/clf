import Foundation

/// 잔여량 밴드. 숫자는 남은 양이므로 클수록 좋다.
/// docs/design/02-domain-model.md 7절
public enum HeadroomBand: Sendable, Equatable {
    case ample      // 50% 이상. 녹색
    case normal     // 15% 이상 50% 미만. 기본색
    case low        // 5% 이상 15% 미만. 노랑
    case empty      // 5% 미만. 빨강
}

public let emptyBandThreshold = 0.05
public let ampleBandThreshold = 0.50

/// lowThreshold 는 선제 전환 임계값과 같은 값을 넘겨받는다.
/// 두 값이 어긋나면 "노란데 아직 새 대화가 이 조직으로 가네" 같은 모순이 생긴다.
public func band(remaining: Double, lowThreshold: Double = 0.15) -> HeadroomBand {
    if remaining < emptyBandThreshold { return .empty }
    if remaining < lowThreshold       { return .low }
    if remaining < ampleBandThreshold { return .normal }
    return .ample
}

/// 이 요청을 묶는 창의 잔여 비율. 없으면 nil.
///
/// 세 창을 본다. 5시간, 전체 주간, 그리고 **요청한 모델의 주간**.
/// 마지막 것은 Usage API 가 있을 때만 채워지며 없으면 두 창으로 줄어든다.
///
/// resetsAt 이 지난 창의 읽기는 버린다. 그 창은 이미 리셋됐으므로 스냅샷이 말하는
/// 소비는 존재하지 않는다. 아직 안 지난 창이면 소비는 늘기만 하므로 묵은 값도
/// 유효한 하한이다.
///
/// requireKnownReset 은 resetsAt 을 모를 때의 처리를 가른다.
///   활성 조직 판단 -> true.  만료를 모르는 묵은 낮은 값이 강등을 유발하면 안 된다
///   후보 조직 판단 -> false. 묵은 낮은 값은 그 후보를 뒤로 밀 뿐이라 안전하다
public func bindingHeadroom(
    _ snapshot: RateLimitSnapshot?,
    for model: ModelID,
    now: Date,
    requireKnownReset: Bool
) -> Double? {
    guard let snapshot else { return nil }

    func usable(_ window: Window?) -> Double? {
        guard let window else { return nil }
        guard let resetsAt = window.resetsAt else {
            return requireKnownReset ? nil : window.remaining
        }
        return resetsAt < now ? nil : window.remaining
    }

    return [usable(snapshot.fiveHour),
            usable(snapshot.sevenDayAll),
            usable(snapshot.modelWeekly[model])].compactMap { $0 }.min()
}
