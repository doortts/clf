import XCTest
@testable import ClfDesktop

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

/// 쿠키가 앱을 못 따라올 때가 있다.
///
/// `lastActiveOrg` 는 서버가 내려주는 값이라 앱에서 계정을 바꿔도 그대로일 수
/// 있다. 실제로 T40 으로 옮긴 뒤에도 막대가 하루 넘게 T52 를 가리켰다.
/// `config.json` 에 계정마다 남는 연 시각이 그 어긋남을 잡아 준다.
final class ActiveOrgFromOpenedAtTests: XCTestCase {
    let at = { (day: Int) in Date(timeIntervalSince1970: Double(day) * 86400) }

    func test_takesTheOrgOpenedAfterTheCookie() {
        let opened = ["t52": at(1), "t40": at(2)]
        XCTAssertEqual(DesktopReader.activeOrg(cookieOrg: "t52", openedAt: opened), "t40")
    }

    func test_keepsTheCookieWhenItIsTheNewest() {
        let opened = ["t52": at(3), "t40": at(2)]
        XCTAssertEqual(DesktopReader.activeOrg(cookieOrg: "t52", openedAt: opened), "t52")
    }

    /// 쿠키가 가리키는 계정에 연 시각이 없으면 견줄 것이 없다. 남의 시각만
    /// 보고 옮겨 가면 엉뚱한 계정에 활성 표시가 붙는다.
    func test_keepsTheCookieWhenItHasNoStamp() {
        XCTAssertEqual(DesktopReader.activeOrg(cookieOrg: "t52", openedAt: ["t40": at(2)]), "t52")
    }

    func test_keepsTheCookieWhenNothingIsStamped() {
        XCTAssertEqual(DesktopReader.activeOrg(cookieOrg: "t52", openedAt: [:]), "t52")
    }

    func test_readsStampsFromConfigKeys() {
        let root: [String: Any] = [
            "dxt:allowlistLastUpdated:t40": "2026-08-31T03:03:26.824Z",
            "dxt:allowlistLastUpdated:t52": "2026-08-30T15:38:59Z",
            "dxt:allowlistEnabled:t40": false,
            "lastKnownAccountUuid": "914e4f12",
        ]
        let opened = DesktopReader.openedAt(config: root)
        XCTAssertEqual(Set(opened.keys), ["t40", "t52"])
        XCTAssertEqual(DesktopReader.activeOrg(cookieOrg: "t52", openedAt: opened), "t40")
    }

    /// 날짜가 아닌 값은 뺀다. 못 읽으면 쿠키만 남아 옛 동작 그대로다.
    func test_ignoresUnparsableStamps() {
        let root: [String: Any] = ["dxt:allowlistLastUpdated:t40": "어제"]
        XCTAssertTrue(DesktopReader.openedAt(config: root).isEmpty)
    }
}
