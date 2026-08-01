import Foundation

/// 갱신 주기를 사용량 변화에 맞춘다.
///
/// 5분이 기본이다. 아무것도 안 변한 관측이 세 번 이어지면 조용하다고 보고
/// 10분으로 늘리고, 변화가 보이면 곧바로 5분으로 돌아온다.
///
/// **느려지는 건 천천히, 빨라지는 건 즉시.** 반대로 하면 한도가 차오르는
/// 구간에서 숫자가 늦게 따라온다. 그때가 이 앱을 볼 유일한 이유인데.
public struct RefreshPacer: Sendable {
    public static let activeInterval = Duration.seconds(300)
    public static let idleInterval = Duration.seconds(600)
    /// 429 를 받았을 때. 창이 언제 열리는지 서버가 안 알려주므로 넉넉히 쉰다.
    public static let throttledInterval = Duration.seconds(900)
    /// 몇 번 연속 그대로여야 조용하다고 볼지.
    public static let idleThreshold = 3

    /// 연속으로 변화가 없었던 횟수. 첫 관측은 비교 대상이 없어 세지 않는다.
    public private(set) var idleStreak = 0
    private var backedOff = false
    private var fingerprint: String?

    public init() {}

    public var currentInterval: Duration {
        if backedOff { return Self.throttledInterval }
        return idleStreak >= Self.idleThreshold ? Self.idleInterval : Self.activeInterval
    }

    /// 스냅샷 하나를 보고 다음 주기를 돌려준다.
    @discardableResult
    public mutating func observe(_ snapshot: DesktopSnapshot) -> Duration {
        backedOff = snapshot.throttled
        // 막힌 동안 값이 그대로인 것은 조용한 게 아니다
        if snapshot.throttled { idleStreak = 0; return currentInterval }

        guard let current = Self.fingerprint(of: snapshot) else {
            // 아무것도 못 읽었으면 정보가 없는 것이다. 조용하다고 단정하지 않는다.
            // 여기서 느려지면 API 가 돌아왔을 때 알아차리는 데 오래 걸린다
            idleStreak = 0
            return currentInterval
        }
        defer { fingerprint = current }
        guard let previous = fingerprint else { return currentInterval }
        idleStreak = current == previous ? idleStreak + 1 : 0
        return currentInterval
    }

    /// 읽어낸 사용률과 활성 조직을 담는다. 읽은 시각은 매번 바뀌므로 넣으면
    /// 영영 안 느려진다. 조직이 늘거나 줄어도, 창이 리셋돼 0 으로 떨어져도
    /// 다르게 나온다.
    ///
    /// **활성 조직을 빠뜨렸던 것이 버그였다.** 사용자가 앱에서 조직을 바꿨는데
    /// 숫자가 그대로면 조용한 것으로 보고 주기를 늘려, 메뉴바가 한참 옛 조직을
    /// 가리켰다. 전환은 활동이다.
    static func fingerprint(of snapshot: DesktopSnapshot) -> String? {
        let active = snapshot.active?.uuid ?? "-"
        let parts = snapshot.orgs
            .filter(\.hasUsage)
            .sorted { $0.uuid < $1.uuid }
            .map { org in
                let windows = org.limits
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue):\($0.value.percentUsed)" }
                    .joined(separator: ",")
                // 예산도 활동이다. 시간 창이 없는 조직은 이것만 움직인다
                let money = org.spend.map { ",$:\($0.usedMinor)" } ?? ""
                return org.uuid + "=" + windows + money
            }
        return parts.isEmpty ? nil : (active + "#" + parts.joined(separator: "|"))
    }
}
