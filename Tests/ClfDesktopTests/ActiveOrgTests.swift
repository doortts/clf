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
/// 있다. 실제로 T52 로 옮긴 뒤에도 막대가 몇 시간 동안 T40 을 가리켰다. 앱이
/// 자기 로그에 적어 둔 요청 URL 이 그 어긋남을 잡아 준다.
final class OrgTraceTests: XCTestCase {
    let t52 = "2a063dae-21bd-4040-ad6c-69e633ed6639"
    let t40 = "746e81ae-c1e7-4402-a1af-7a3cf49a7fa5"

    func scope(_ urls: [String?]) -> Data {
        let crumbs: [[String: Any]] = urls.map { url in
            guard let url else { return ["category": "electron", "message": "window.focus"] }
            return ["category": "electron.net", "data": ["url": url, "method": "GET"]]
        }
        return try! JSONSerialization.data(withJSONObject: ["scope": ["breadcrumbs": crumbs]])
    }

    /// 계정을 바꾸면 새 계정으로 요청이 나간다. 마지막 것이 지금 계정이다.
    func test_takesTheLastOrgTheAppCalled() {
        let data = scope([
            "https://claude.ai/api/organizations/\(t40)/skills/list-skills",
            nil,
            "https://claude.ai/api/organizations/\(t52)/plugins/list-plugins",
        ])
        XCTAssertEqual(OrgTrace.lastOrg(scope: data), t52)
    }

    /// 계정 URL 뒤에 나온 다른 요청이 답을 가리지 않는다.
    func test_skipsCrumbsWithoutAnOrg() {
        let data = scope([
            "https://claude.ai/api/bootstrap/\(t52)/current_user_access",
            "https://api.github.com/repos/doortts/clf/pulls",
            nil,
        ])
        XCTAssertEqual(OrgTrace.lastOrg(scope: data), t52)
    }

    /// 100개짜리 고리에 계정 URL 이 하나도 없을 수 있다. 그때는 쿠키를 쓴다.
    func test_returnsNilWhenNoCrumbNamesAnOrg() {
        XCTAssertNil(OrgTrace.lastOrg(scope: scope([nil, "https://claude.ai/api/organizations"])))
        XCTAssertNil(OrgTrace.lastOrg(scope: Data("{}".utf8)))
        XCTAssertNil(OrgTrace.lastOrg(scope: Data("깨진 값".utf8)))
    }

    func test_readsBothOrgScopedShapes() {
        XCTAssertEqual(
            OrgTrace.org(inURL: "https://claude.ai/api/organizations/\(t40)/skills/list-skills"),
            t40)
        XCTAssertEqual(
            OrgTrace.org(inURL: "https://claude.ai/api/bootstrap/\(t52)/current_user_access"),
            t52)
        XCTAssertEqual(OrgTrace.org(inURL: "https://claude.ai/api/organizations/\(t52)"), t52)
        XCTAssertEqual(OrgTrace.org(inURL: "https://claude.ai/api/bootstrap/\(t52)?x=1"), t52)
    }

    /// 사람이나 대화의 uuid 를 계정으로 읽으면 활성 표시가 통째로 사라진다.
    /// 계정 uuid 를 담는 두 갈래만 본다.
    func test_ignoresUUIDsThatAreNotOrgs() {
        XCTAssertNil(OrgTrace.org(inURL: "https://claude.ai/api/account/\(t52)"))
        XCTAssertNil(OrgTrace.org(inURL: "https://claude.ai/api/organizations/personal/x"))
        XCTAssertNil(OrgTrace.org(inURL: "https://claude.ai/api/organizations/"))
        XCTAssertNil(OrgTrace.org(inURL: "https://evil.example/api/organizations/\(t52)"))
    }
}
