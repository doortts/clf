import XCTest
@testable import ClfDesktop

private func limit(_ used: Int) -> UsageLimit {
    UsageLimit(percentUsed: used, resetsAt: nil, severity: "normal")
}
private func snapshot(_ session: Int, weekly: Int = 10) -> DesktopSnapshot {
    DesktopSnapshot(
        orgs: [OrgUsage(uuid: "a", name: "A", isActive: true, plan: "team",
                        limits: [.session: limit(session), .weeklyAll: limit(weekly)])],
        unreadable: [], readAt: Date())
}

/// 갱신 주기를 사용량 변화에 맞춘다.
///
/// 5분이 기본. 아무것도 안 변한 관측이 세 번 이어지면 10분으로 늘리고,
/// 변화가 보이면 곧바로 5분으로 돌아온다.
final class RefreshPacerTests: XCTestCase {

    func test_startsAtActiveInterval() {
        var pacer = RefreshPacer()
        XCTAssertEqual(pacer.observe(snapshot(10)), RefreshPacer.activeInterval)
    }

    /// 첫 관측은 비교 대상이 없다. 안 변했다고 셀 수 없다.
    func test_firstObservationIsNotIdle() {
        var pacer = RefreshPacer()
        _ = pacer.observe(snapshot(10))
        XCTAssertEqual(pacer.idleStreak, 0)
    }

    func test_slowsDownAfterThreeUnchanged() {
        var pacer = RefreshPacer()
        _ = pacer.observe(snapshot(10))                  // 기준
        XCTAssertEqual(pacer.observe(snapshot(10)), RefreshPacer.activeInterval)  // 1
        XCTAssertEqual(pacer.observe(snapshot(10)), RefreshPacer.activeInterval)  // 2
        XCTAssertEqual(pacer.observe(snapshot(10)), RefreshPacer.idleInterval)    // 3
        XCTAssertEqual(pacer.observe(snapshot(10)), RefreshPacer.idleInterval)
    }

    /// 변화가 보이면 곧바로 되돌아온다. 다시 세 번 기다리지 않는다.
    func test_changeSnapsBackImmediately() {
        var pacer = RefreshPacer()
        for _ in 0..<5 { _ = pacer.observe(snapshot(10)) }
        XCTAssertEqual(pacer.currentInterval, RefreshPacer.idleInterval)

        XCTAssertEqual(pacer.observe(snapshot(11)), RefreshPacer.activeInterval)
        XCTAssertEqual(pacer.idleStreak, 0)
    }

    /// 어느 창이 변하든 활동이다. 5시간만 보지 않는다.
    func test_anyWindowCountsAsActivity() {
        var pacer = RefreshPacer()
        for _ in 0..<5 { _ = pacer.observe(snapshot(10, weekly: 10)) }
        XCTAssertEqual(pacer.observe(snapshot(10, weekly: 11)), RefreshPacer.activeInterval)
    }

    /// 창이 리셋되면 사용률이 0 으로 떨어진다. 그것도 변화다.
    func test_windowResetIsAChange() {
        var pacer = RefreshPacer()
        for _ in 0..<5 { _ = pacer.observe(snapshot(90)) }
        XCTAssertEqual(pacer.observe(snapshot(0)), RefreshPacer.activeInterval)
    }

    /// 읽는 시각은 매번 바뀐다. 그걸 변화로 세면 영영 안 느려진다.
    func test_readTimeAloneIsNotActivity() {
        var pacer = RefreshPacer()
        var first = snapshot(10)
        _ = pacer.observe(first)
        for _ in 0..<3 {
            first = DesktopSnapshot(orgs: first.orgs, unreadable: [],
                                    readAt: Date().addingTimeInterval(600))
            _ = pacer.observe(first)
        }
        XCTAssertEqual(pacer.currentInterval, RefreshPacer.idleInterval)
    }

    /// 아무것도 못 읽었으면 정보가 없는 것이다. 조용하다고 단정하지 않는다.
    /// 여기서 느려지면 API 가 돌아왔을 때 알아차리는 데 오래 걸린다.
    func test_failedReadDoesNotCountAsIdle() {
        var pacer = RefreshPacer()
        _ = pacer.observe(snapshot(10))
        let broken = DesktopSnapshot(
            orgs: [OrgUsage(uuid: "a", name: "A", isActive: true, plan: nil,
                            limits: [:], error: "토큰 만료")],
            unreadable: [], readAt: Date())
        for _ in 0..<5 { _ = pacer.observe(broken) }
        XCTAssertEqual(pacer.currentInterval, RefreshPacer.activeInterval)
    }

    /// 조직이 늘거나 줄어도 변화다.
    func test_orgSetChangeIsActivity() {
        var pacer = RefreshPacer()
        for _ in 0..<5 { _ = pacer.observe(snapshot(10)) }
        let more = DesktopSnapshot(
            orgs: snapshot(10).orgs + [OrgUsage(uuid: "b", name: "B", isActive: false,
                                                plan: "team", limits: [.session: limit(5)])],
            unreadable: [], readAt: Date())
        XCTAssertEqual(pacer.observe(more), RefreshPacer.activeInterval)
    }
}

/// 메뉴바 막대에 무엇을 그릴지.
final class BarContentTests: XCTestCase {

    static func some(_ used: Int) -> [LimitKind: UsageLimit] {
        [.session: UsageLimit(percentUsed: used, resetsAt: nil, severity: "normal")]
    }

    let orgs = [
        OrgUsage(uuid: "t40", name: "TEAM_40", isActive: true, plan: "team", limits: some(10)),
        OrgUsage(uuid: "t52", name: "TEAM_52", isActive: false, plan: "team", limits: some(20)),
        OrgUsage(uuid: "ent", name: "Naver", isActive: false, plan: "enterprise", limits: some(30)),
    ]

    /// 기본은 창이 열려 있는 계정만. 셋을 다 그리면 막대가 길어진다.
    func test_defaultIsWindowedOnly() {
        let prefs = DesktopPreferences()
        XCTAssertEqual(prefs.barContent, .windowed)
        XCTAssertEqual(prefs.barOrgs(from: orgs).map(\.uuid), ["t40"])
    }

    /// 별도 창을 띄운 계정도 창이 열린 것이다. 기본 창 계정과 함께 나온다.
    func test_windowedIncludesSeparateWindows() {
        let prefs = DesktopPreferences()
        XCTAssertEqual(prefs.barOrgs(from: orgs, withWindow: ["t52"]).map(\.uuid),
                       ["t40", "t52"])
    }

    /// 창이 열려 있으면 설정에서 껐어도 막대에 올린다. 이 항목은 설정이
    /// 아니라 창을 보는 것이다.
    func test_windowedIgnoresTheHiddenList() {
        var prefs = DesktopPreferences()
        prefs.hidden = ["t52"]
        XCTAssertEqual(prefs.barOrgs(from: orgs, withWindow: ["t52"]).map(\.uuid),
                       ["t40", "t52"])
    }

    func test_chosenShowsEveryPickedOrg() {
        var prefs = DesktopPreferences()
        prefs.barContent = .chosen
        XCTAssertEqual(prefs.barOrgs(from: orgs).map(\.uuid), ["t40", "ent", "t52"])
    }

    /// 설정에서 끈 계정은 그 항목에서만 빠진다. 창이 떠 있어도 마찬가지다.
    func test_chosenFollowsTheHiddenList() {
        var prefs = DesktopPreferences()
        prefs.barContent = .chosen
        prefs.hidden = ["t52"]
        XCTAssertEqual(prefs.barOrgs(from: orgs, withWindow: ["t52"]).map(\.uuid),
                       ["t40", "ent"])
    }

    /// 창이 하나도 없으면 막대가 빈다. 빈 막대보다는 첫째를 쓴다.
    func test_windowedFallsBackWhenNoWindowIsOpen() {
        let idle = orgs.map {
            OrgUsage(uuid: $0.uuid, name: $0.name, isActive: false, plan: $0.plan,
                     limits: $0.limits)
        }
        XCTAssertEqual(DesktopPreferences().barOrgs(from: idle).count, 1)
    }

    /// 사용량을 모르는 조직은 막대에 안 올린다. `?` 와 빈 게이지는 자리만
    /// 먹고 알려주는 것이 없다.
    func test_unreadableOrgsStayOffTheBar() {
        var prefs = DesktopPreferences()
        prefs.barContent = .chosen
        let mixed = orgs.dropLast() + [
            OrgUsage(uuid: "ent", name: "Naver", isActive: false, plan: nil, limits: [:],
                     error: "앱에서 이 조직을 한 번 열면 사용량이 읽힌다")]
        XCTAssertEqual(prefs.barOrgs(from: Array(mixed)).map(\.uuid), ["t40", "t52"])
    }

    /// 팝오버와 설정에는 그대로 남는다. 거기서는 왜 못 읽는지까지 말할 수 있다.
    func test_unreadableOrgsStillShowInThePopover() {
        let mixed = orgs.dropLast() + [
            OrgUsage(uuid: "ent", name: "Naver", isActive: false, plan: nil, limits: [:])]
        XCTAssertEqual(DesktopPreferences().apply(to: Array(mixed)).count, 3)
    }

    /// 낡은 값은 값이다. 429 로 갱신을 못 했다고 막대에서 사라지면 안 된다.
    func test_staleOrgsKeepTheirSlot() {
        var prefs = DesktopPreferences()
        prefs.barContent = .chosen
        let stale = [OrgUsage(uuid: "t40", name: "TEAM_40", isActive: true, plan: "team",
                              limits: Self.some(10), error: "요청이 너무 잦다", isStale: true)]
        XCTAssertEqual(prefs.barOrgs(from: stale).count, 1)
    }

    /// 아무것도 못 읽었으면 막대가 빈다. 그때는 앱 이름이 뜬다.
    func test_barIsEmptyWhenNothingIsKnown() {
        let blind = orgs.map {
            OrgUsage(uuid: $0.uuid, name: $0.name, isActive: $0.isActive, plan: nil, limits: [:])
        }
        XCTAssertTrue(DesktopPreferences().barOrgs(from: blind).isEmpty)
        XCTAssertEqual(BarText.label(for: []), BarText.placeholder)
    }

    func test_emptyWhenEverythingHidden() {
        var prefs = DesktopPreferences()
        prefs.barContent = .chosen
        prefs.hidden = ["t40", "t52", "ent"]
        XCTAssertTrue(prefs.barOrgs(from: orgs).isEmpty)
    }

    /// 계정 목록이 막대를 정하는지 아닌지가 고른 칸에 따라 다르다. 제목만
    /// 보고 목록을 껐는데 막대가 그대로면 어리둥절해진다.
    func test_listNoteSaysWhetherTheListDrivesTheBar() {
        XCTAssertTrue(BarContent.chosen.listNote.contains("팝오버"))
        XCTAssertTrue(BarContent.windowed.listNote.contains("창을 보고"))
        XCTAssertNotEqual(BarContent.chosen.listNote, BarContent.windowed.listNote)
    }

    func test_barContentSurvivesRoundTrip() throws {
        var prefs = DesktopPreferences()
        prefs.barContent = .chosen
        let data = try JSONEncoder().encode(prefs)
        XCTAssertEqual(try JSONDecoder().decode(DesktopPreferences.self, from: data).barContent,
                       .chosen)
    }

    /// 이름을 바꾸기 전에 저장된 파일도 읽는다. 설정이 초기화되면 안 된다.
    func test_readsTheOldNames() throws {
        func read(_ raw: String) throws -> BarContent {
            try JSONDecoder().decode(DesktopPreferences.self,
                                     from: Data(#"{"barContent":"\#(raw)"}"#.utf8)).barContent
        }
        XCTAssertEqual(try read("active_only"), .windowed)
        XCTAssertEqual(try read("all_visible"), .chosen)
    }

    /// 옛 파일에는 이 항목이 없다. 기본값으로 읽혀야 한다.
    func test_missingBarContentDefaults() throws {
        let sparse = Data(#"{"version":1}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(DesktopPreferences.self, from: sparse).barContent,
                       .windowed)
    }
}

/// 429 를 받으면 물러선다.
///
/// 실측으로 만났다. Usage API 는 짧은 시간에 여러 번 부르면 429 를 준다.
/// 그때 5분마다 계속 두드리면 창이 안 열린다.
final class ThrottleBackoffTests: XCTestCase {
    private func throttled() -> DesktopSnapshot {
        DesktopSnapshot(
            orgs: [OrgUsage(uuid: "a", name: "A", isActive: true, plan: "team",
                            limits: [:], error: "요청이 너무 잦다")],
            unreadable: [], throttled: true, readAt: Date())
    }
    private func ok(_ used: Int) -> DesktopSnapshot {
        DesktopSnapshot(
            orgs: [OrgUsage(uuid: "a", name: "A", isActive: true, plan: "team",
                            limits: [.session: UsageLimit(percentUsed: used, resetsAt: nil,
                                                          severity: "normal")])],
            unreadable: [], readAt: Date())
    }

    /// 한 번만 받아도 곧바로 물러선다. 세 번 기다릴 일이 아니다.
    func test_backsOffOnTheFirstThrottle() {
        var pacer = RefreshPacer()
        _ = pacer.observe(ok(10))
        XCTAssertEqual(pacer.observe(throttled()), RefreshPacer.throttledInterval)
    }

    /// 물러난 간격은 조용할 때보다 길어야 한다. 안 그러면 물러난 게 아니다.
    func test_throttledIsTheLongestInterval() {
        XCTAssertGreaterThan(RefreshPacer.throttledInterval, RefreshPacer.idleInterval)
    }

    /// 풀리면 바로 돌아온다.
    func test_recoversOnTheNextGoodRead() {
        var pacer = RefreshPacer()
        _ = pacer.observe(throttled())
        XCTAssertEqual(pacer.observe(ok(10)), RefreshPacer.activeInterval)
    }

    /// 막힌 동안 값이 그대로인 것은 조용한 게 아니다. 물러난 상태를 유지한다.
    func test_repeatedThrottlingStaysBackedOff() {
        var pacer = RefreshPacer()
        for _ in 0..<5 { _ = pacer.observe(throttled()) }
        XCTAssertEqual(pacer.currentInterval, RefreshPacer.throttledInterval)
        XCTAssertEqual(pacer.idleStreak, 0)
    }
}
