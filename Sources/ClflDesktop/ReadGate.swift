import Foundation

/// 언제 다시 읽어도 되는지.
///
/// 팝오버를 열 때마다 읽으면 몇 번 여닫는 것으로 429 가 온다. 실제로 그랬다.
/// 한 번 읽을 때 요청이 조직 수만큼 나가므로 조직 셋이면 여닫기 다섯 번에
/// 스무 건이다.
///
/// 주기는 `RefreshPacer` 가 정하고, 그와 별개로 사람이 유발하는 읽기를 여기서
/// 막는다. 둘은 하는 일이 다르다. 페이서는 얼마나 자주 볼지, 이 문은 지금
/// 눌러도 되는지.
public struct ReadGate: Sendable {
    /// 사람이 유발한 읽기 사이의 최소 간격. 화면에는 방금 읽은 값이 이미 있다.
    public static let quietWindow: TimeInterval = 60
    /// 429 를 받은 뒤. 여기서 더 두드리면 창이 안 열린다.
    public static let throttledWindow: TimeInterval = 900

    public private(set) var nextAllowed: Date?
    /// 마지막 읽기가 429 였나. 그때는 주기 루프도 막는다.
    public private(set) var blocked = false

    public init() {}

    public func allows(at now: Date, scheduled: Bool = false) -> Bool {
        guard let nextAllowed else { return true }
        // 주기 루프는 자기 시계를 따른다. 문까지 통과해야 하면 둘이 싸운다.
        // 다만 429 는 서버가 그만 물어보라고 한 것이라 루프도 세운다
        if scheduled && !blocked { return true }
        return now >= nextAllowed
    }

    public mutating func record(at now: Date, throttled: Bool) {
        blocked = throttled
        nextAllowed = now.addingTimeInterval(throttled ? Self.throttledWindow : Self.quietWindow)
    }

    /// 사용자에게 할 말. 없으면 조용히 넘어간다.
    ///
    /// 방금 읽어서 안 읽은 것은 알릴 일이 아니다. 화면에는 방금 값이 이미
    /// 있고 "요청이 몰렸다" 는 말은 사실도 아니다. **429 일 때만 말한다.**
    /// 그때는 값이 낡은 채로 멈춰 있는 이유가 되기 때문이다.
    public func complaint(at now: Date) -> String? {
        guard blocked, let nextAllowed, now < nextAllowed else { return nil }
        return BarText.until(nextAllowed, from: now)
    }
}

/// 실패한 조직에 마지막으로 읽은 값을 물려준다.
///
/// 이것이 "아무것도 안 보인다" 의 원인이었다. 한 조직이 429 를 맞으면 빈
/// `limits` 로 갈아치워서 방금까지 보이던 숫자가 사라졌다.
///
/// **값은 옛것을 쓰고 사유는 새것을 남긴다.** 값만 남기면 사용자가 옛 값을
/// 지금 값으로 믿는다.
public func mergeKeepingLastGood(fresh: [OrgUsage], previous: [OrgUsage]) -> [OrgUsage] {
    let old = Dictionary(previous.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
    return fresh.map { org in
        guard org.limits.isEmpty,
              let last = old[org.uuid], !last.limits.isEmpty
        else { return org }
        return OrgUsage(uuid: org.uuid, name: org.name, isActive: org.isActive,
                        plan: org.plan ?? last.plan, limits: last.limits,
                        error: org.error, isStale: true)
    }
}

/// `사용 중` 표시를 옮긴다. 숫자는 손대지 않는다.
///
/// 어느 조직이 활성인지는 로컬 쿠키에 있어 네트워크 없이 알 수 있다.
/// 사용량을 다시 읽기 전에 표시부터 옮겨야 화면이 곧바로 사실을 말한다.
///
/// 모르는 조직으로 옮겨갔으면 아무것도 활성이 아니다. 엉뚱한 곳에 표시를
/// 남기느니 없는 편이 낫다.
public func reassignActive(to uuid: String?, in orgs: [OrgUsage]) -> [OrgUsage] {
    orgs.map { org in
        guard org.isActive != (org.uuid == uuid) else { return org }
        return OrgUsage(uuid: org.uuid, name: org.name, isActive: org.uuid == uuid,
                        plan: org.plan, limits: org.limits, error: org.error,
                        isStale: org.isStale)
    }
}
