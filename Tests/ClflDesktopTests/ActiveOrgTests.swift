import XCTest
@testable import ClflDesktop

private func limit(_ used: Int) -> UsageLimit {
    UsageLimit(percentUsed: used, resetsAt: nil, severity: "normal")
}
private func org(_ uuid: String, _ used: Int, active: Bool) -> OrgUsage {
    OrgUsage(uuid: uuid, name: uuid.uppercased(), isActive: active, plan: "team",
             limits: [.session: limit(used)])
}
private func snap(_ orgs: [OrgUsage]) -> DesktopSnapshot {
    DesktopSnapshot(orgs: orgs, unreadable: [], readAt: Date())
}

/// 데스크톱 앱에서 조직을 바꾸면 우리도 곧바로 따라가야 한다.
final class ActiveOrgChangeTests: XCTestCase {

    /// **이것이 버그였다.** 지문에 사용률만 담아서, 조직만 바뀌고 숫자가
    /// 그대로면 조용한 것으로 보고 주기를 10분으로 늘렸다. 전환은 활동이다.
    func test_switchingOrgIsActivity() {
        var pacer = RefreshPacer()
        let before = snap([org("a", 10, active: true), org("b", 20, active: false)])
        for _ in 0..<5 { _ = pacer.observe(before) }
        XCTAssertEqual(pacer.currentInterval, RefreshPacer.idleInterval)

        let after = snap([org("a", 10, active: false), org("b", 20, active: true)])
        XCTAssertEqual(pacer.observe(after), RefreshPacer.activeInterval)
    }

    /// 활성 조직이 그대로면 여전히 조용한 것이다.
    func test_sameActiveOrgStaysQuiet() {
        var pacer = RefreshPacer()
        let s = snap([org("a", 10, active: true)])
        for _ in 0..<5 { _ = pacer.observe(s) }
        XCTAssertEqual(pacer.currentInterval, RefreshPacer.idleInterval)
    }
}

/// 활성 표시는 네트워크 없이 바로 고칠 수 있다.
///
/// 어느 조직이 활성인지는 로컬 쿠키에 있다. 사용량을 다시 읽지 않고도
/// `사용 중` 표시를 옮길 수 있으므로 먼저 옮기고 숫자는 나중에 맞춘다.
final class ReassignActiveTests: XCTestCase {
    let orgs = [org("a", 10, active: true), org("b", 20, active: false)]

    func test_movesTheMarker() {
        let after = reassignActive(to: "b", in: orgs)
        XCTAssertEqual(after.first { $0.isActive }?.uuid, "b")
        XCTAssertEqual(after.filter(\.isActive).count, 1)
    }

    /// 숫자는 손대지 않는다. 표시만 옮기는 것이다.
    func test_keepsEverythingElse() {
        let after = reassignActive(to: "b", in: orgs)
        XCTAssertEqual(after.map(\.uuid), ["a", "b"])
        XCTAssertEqual(after[0].limits[.session]?.percentUsed, 10)
        XCTAssertEqual(after[1].limits[.session]?.percentUsed, 20)
    }

    /// 모르는 조직으로 옮겨갔으면 아무것도 활성이 아니다. 엉뚱한 곳에
    /// 표시를 남기느니 없는 편이 낫다.
    func test_unknownTargetClearsTheMarker() {
        XCTAssertTrue(reassignActive(to: "zzz", in: orgs).allSatisfy { !$0.isActive })
    }

    func test_nilTargetClearsTheMarker() {
        XCTAssertTrue(reassignActive(to: nil, in: orgs).allSatisfy { !$0.isActive })
    }
}
