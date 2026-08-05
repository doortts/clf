import Foundation

/// 빨강에 들어섰던 계정을 기억해 두고, 리셋으로 풀렸을 때 한 번만 알린다.
///
/// **리셋 자체는 소식이 아니다.** 5시간 창은 하루에 몇 번씩 리셋되고 그때마다
/// 알리면 알림을 꺼 버린다. 알릴 값이 있는 것은 *막혀서 기다리던 사람이 이제
/// 다시 쓸 수 있게 된 순간* 하나다. 그래서 빨강에 들어선 계정만 기억하고,
/// 그 계정이 빨강을 벗어날 때만 알린다.
///
/// 판단은 **막고 있는 창**의 잔여로 한다. 5시간 창이 리셋됐어도 주간이
/// 소진이면 실제로는 아직 못 쓴다. 그런 리셋은 알리지 않는다.
/// docs/design/notify-mockup.html
public struct RecoveryWatch: Sendable, Equatable {
    /// 빨강에 들어선 것을 본 계정.
    private var red: Set<String>

    public init(red: Set<String> = []) {
        self.red = red
    }

    /// 지금 기억하고 있는 계정. 테스트와 디버깅용이다.
    public var watching: Set<String> { red }

    /// 이번 읽기를 반영하고, 방금 풀린 계정을 돌려준다.
    ///
    /// **읽지 못한 계정은 건드리지 않는다.** 읽기가 한 번 실패했다고 기억을
    /// 지우면 그 계정이 풀렸을 때 알릴 근거가 사라진다.
    public mutating func step(_ orgs: [OrgUsage]) -> [OrgUsage] {
        var recovered: [OrgUsage] = []
        for org in orgs {
            guard let left = UsageAlerts.remaining(of: org) else { continue }
            if left <= UsageAlerts.warnBelow {
                red.insert(org.uuid)
            } else if red.remove(org.uuid) != nil {
                recovered.append(org)
            }
        }
        return recovered
    }

    /// 지금 상태를 기억만 한다. 알림은 안 만든다.
    ///
    /// 앱을 켠 직후 첫 읽기와 알림을 꺼 둔 동안에 쓴다. 이미 빨강인 채로 켠
    /// 것은 새 소식이 아니지만, 그 사실을 기억해 둬야 나중에 풀릴 때 알릴 수
    /// 있다.
    public mutating func seed(_ orgs: [OrgUsage]) {
        _ = step(orgs)
    }
}
