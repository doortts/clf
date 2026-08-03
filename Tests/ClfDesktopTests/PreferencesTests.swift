import XCTest
@testable import ClfDesktop

private func org(_ uuid: String, _ name: String, active: Bool = false,
                 plan: String = "team") -> OrgUsage {
    OrgUsage(uuid: uuid, name: name, isActive: active, plan: plan, limits: [:])
}

/// 어느 조직을 메뉴바에 보여줄지. 사람마다 조합이 다르다.
/// 팀 둘에 Enterprise 하나, 팀 하나에 Enterprise 하나, Enterprise 만.
final class PreferencesTests: XCTestCase {

    let all = [org("t40", "NAVER_TEAM_40", active: true),
               org("t52", "NAVER_TEAM_52"),
               org("ent", "Naver", plan: "enterprise")]

    /// 아무것도 설정하지 않았으면 전부 보인다. 처음 켰을 때 빈 화면이면 안 된다.
    func test_showsEverythingByDefault() {
        let visible = DesktopPreferences().apply(to: all)
        XCTAssertEqual(visible.map(\.uuid), ["t40", "t52", "ent"])
    }

    /// 기본 순서는 활성 조직이 먼저, 나머지는 이름순.
    func test_defaultOrderPutsActiveFirst() {
        let shuffled = [org("ent", "Naver", plan: "enterprise"),
                        org("t52", "NAVER_TEAM_52"),
                        org("t40", "NAVER_TEAM_40", active: true)]
        XCTAssertEqual(DesktopPreferences().apply(to: shuffled).map(\.name),
                       ["NAVER_TEAM_40", "NAVER_TEAM_52", "Naver"])
    }

    // MARK: 숨기기

    func test_hiddenOrgIsDropped() {
        var prefs = DesktopPreferences()
        prefs.hidden = ["t52"]
        XCTAssertEqual(prefs.apply(to: all).map(\.uuid), ["t40", "ent"])
    }

    /// Enterprise 만 쓰는 사람. 나머지를 다 숨긴다.
    func test_canHideDownToOne() {
        var prefs = DesktopPreferences()
        prefs.hidden = ["t40", "t52"]
        XCTAssertEqual(prefs.apply(to: all).map(\.uuid), ["ent"])
    }

    /// 전부 숨기면 보여줄 것이 없다. 그것도 사용자의 선택이므로 막지 않는다.
    func test_hidingEverythingYieldsEmpty() {
        var prefs = DesktopPreferences()
        prefs.hidden = ["t40", "t52", "ent"]
        XCTAssertTrue(prefs.apply(to: all).isEmpty)
    }

    /// 쓰지 않는 조직을 숨겨도 목록에서 안 사라진다. 설정 화면은 전부 보여야
    /// 다시 켤 수 있다.
    func test_hidingDoesNotForgetTheOrg() {
        var prefs = DesktopPreferences()
        prefs.hidden = ["t52"]
        XCTAssertTrue(prefs.isHidden("t52"))
        XCTAssertFalse(prefs.isHidden("t40"))
    }

    // MARK: 순서

    func test_explicitOrderWins() {
        var prefs = DesktopPreferences()
        prefs.order = ["ent", "t52", "t40"]
        XCTAssertEqual(prefs.apply(to: all).map(\.uuid), ["ent", "t52", "t40"],
                       "활성 조직 우선보다 사용자가 정한 순서가 앞선다")
    }

    /// 순서에 없는 조직은 뒤에 붙는다. 새로 생긴 조직이 사라지면 안 된다.
    func test_newOrgAppearsAtTheEnd() {
        var prefs = DesktopPreferences()
        prefs.order = ["t52", "t40"]
        XCTAssertEqual(prefs.apply(to: all).map(\.uuid), ["t52", "t40", "ent"])
    }

    /// 순서 목록에 없어진 조직이 남아 있어도 걸러진다.
    func test_staleOrderEntriesAreIgnored() {
        var prefs = DesktopPreferences()
        prefs.order = ["deleted", "t52", "t40", "ent"]
        XCTAssertEqual(prefs.apply(to: all).map(\.uuid), ["t52", "t40", "ent"])
    }

    // MARK: 왕복

    func test_encodesAndDecodes() throws {
        var prefs = DesktopPreferences()
        prefs.hidden = ["t52"]
        prefs.order = ["ent", "t40"]
        let data = try JSONEncoder().encode(prefs)
        XCTAssertEqual(try JSONDecoder().decode(DesktopPreferences.self, from: data), prefs)
    }

    /// 필드가 빠진 옛 파일도 읽혀야 한다. 설정이 안 열리는 것보다 낫다.
    func test_decodesSparseFile() throws {
        let sparse = Data(#"{"version":1}"#.utf8)
        let prefs = try JSONDecoder().decode(DesktopPreferences.self, from: sparse)
        XCTAssertTrue(prefs.hidden.isEmpty)
        XCTAssertEqual(prefs.apply(to: all).count, 3)
    }
}

/// 앱에서 아직 안 연 조직도 설정에서는 다뤄야 한다. 사용자가 쓸 조합에
/// 들어 있는데 목록에 없으면 순서도 못 정하고 미리 숨길 수도 없다.
final class KnownOrgTests: XCTestCase {

    func test_snapshotListsUnreadableOrgsToo() {
        let snapshot = DesktopSnapshot(
            orgs: [OrgUsage(uuid: "t40", name: "NAVER_TEAM_40", isActive: true,
                            plan: "team", limits: [:])],
            unreadable: ["Naver"],
            unreadableByUUID: ["ent": "Naver"],
            readAt: Date())

        XCTAssertEqual(snapshot.knownOrgs.map(\.name), ["NAVER_TEAM_40", "Naver"])
        XCTAssertEqual(snapshot.knownOrgs.last?.uuid, "ent")
    }

    /// 사용량을 못 읽는 것과 조직을 모르는 것은 다르다.
    func test_unreadableOrgCarriesReason() {
        let snapshot = DesktopSnapshot(
            orgs: [], unreadable: ["Naver"],
            unreadableByUUID: ["ent": "Naver"], readAt: Date())
        XCTAssertNotNil(snapshot.knownOrgs.first?.error)
        XCTAssertTrue(snapshot.knownOrgs.first!.limits.isEmpty)
    }

    /// 못 읽는 조직도 순서와 숨김이 걸린다.
    func test_preferencesApplyToUnreadableOrgs() {
        let snapshot = DesktopSnapshot(
            orgs: [OrgUsage(uuid: "t40", name: "A", isActive: true, plan: "team", limits: [:])],
            unreadable: ["Naver"], unreadableByUUID: ["ent": "Naver"], readAt: Date())
        var prefs = DesktopPreferences()
        prefs.order = ["ent", "t40"]
        XCTAssertEqual(prefs.apply(to: snapshot.knownOrgs).map(\.uuid), ["ent", "t40"])

        prefs.hidden = ["ent"]
        XCTAssertEqual(prefs.apply(to: snapshot.knownOrgs).map(\.uuid), ["t40"])
    }
}
