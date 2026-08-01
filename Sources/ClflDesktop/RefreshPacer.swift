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
    /// 몇 번 연속 그대로여야 조용하다고 볼지.
    public static let idleThreshold = 3

    /// 연속으로 변화가 없었던 횟수. 첫 관측은 비교 대상이 없어 세지 않는다.
    public private(set) var idleStreak = 0
    private var fingerprint: String?

    public init() {}

    public var currentInterval: Duration {
        idleStreak >= Self.idleThreshold ? Self.idleInterval : Self.activeInterval
    }

    /// 스냅샷 하나를 보고 다음 주기를 돌려준다.
    @discardableResult
    public mutating func observe(_ snapshot: DesktopSnapshot) -> Duration {
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

    /// 읽어낸 사용률만 담는다. 읽은 시각은 매번 바뀌므로 넣으면 영영 안 느려진다.
    /// 조직이 늘거나 줄어도, 창이 리셋돼 0 으로 떨어져도 다르게 나온다.
    static func fingerprint(of snapshot: DesktopSnapshot) -> String? {
        let parts = snapshot.orgs
            .filter { !$0.limits.isEmpty }
            .sorted { $0.uuid < $1.uuid }
            .map { org in
                org.uuid + "=" + org.limits
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue):\($0.value.percentUsed)" }
                    .joined(separator: ",")
            }
        return parts.isEmpty ? nil : parts.joined(separator: "|")
    }
}
