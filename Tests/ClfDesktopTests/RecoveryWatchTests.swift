import XCTest
@testable import ClfDesktop

/// 리셋으로 풀렸을 때의 알림 판단. docs/design/notify-mockup.html
final class RecoveryWatchTests: XCTestCase {
    private func limit(_ used: Int) -> UsageLimit {
        UsageLimit(percentUsed: used, resetsAt: nil, severity: "")
    }

    private func org(_ limits: [LimitKind: UsageLimit],
                     uuid: String = "u1", name: String = "T52",
                     isStale: Bool = false) -> OrgUsage {
        OrgUsage(uuid: uuid, name: name, isActive: true, plan: "team",
                 limits: limits, isStale: isStale)
    }

    private func spendOrg(_ percentUsed: Int, uuid: String = "e1") -> OrgUsage {
        OrgUsage(uuid: uuid, name: "ENT", isActive: true, plan: "enterprise", limits: [:],
                 spend: SpendUsage(usedMinor: 0, limitMinor: 100_00, currency: "USD",
                                   exponent: 2, percentUsed: percentUsed, severity: ""))
    }

    /// 빨강에 들어섰다가 리셋으로 풀리면 한 번 알린다.
    func test_redThenResetNotifiesOnce() {
        var watch = RecoveryWatch()
        XCTAssertTrue(watch.step([org([.session: limit(97)])]).isEmpty)
        XCTAssertEqual(watch.step([org([.session: limit(10)])]).map(\.uuid), ["u1"])
        // 두 번째 읽기에는 더 알릴 것이 없다
        XCTAssertTrue(watch.step([org([.session: limit(10)])]).isEmpty)
    }

    /// **빨강을 겪지 않은 계정의 리셋은 알리지 않는다.** 5시간 창은 하루에도
    /// 몇 번씩 리셋되고 그때마다 알리면 알림을 꺼 버린다.
    func test_resetWithoutRedIsQuiet() {
        var watch = RecoveryWatch()
        _ = watch.step([org([.session: limit(50)])])
        XCTAssertTrue(watch.step([org([.session: limit(0)])]).isEmpty)
    }

    /// **리셋됐지만 아직 못 쓰는 경우는 알리지 않는다.** 5시간 창이 풀려도
    /// 주간이 소진이면 실제로는 막혀 있다.
    func test_resetBlockedByAnotherWindowIsQuiet() {
        var watch = RecoveryWatch()
        _ = watch.step([org([.session: limit(100), .weeklyAll: limit(100)])])
        let still = watch.step([org([.session: limit(0), .weeklyAll: limit(100)])])
        XCTAssertTrue(still.isEmpty)
        XCTAssertEqual(watch.watching, ["u1"])
        // 주간까지 풀리면 그때 알린다
        XCTAssertEqual(watch.step([org([.session: limit(0), .weeklyAll: limit(20)])])
                        .map(\.uuid), ["u1"])
    }

    /// 빨강 경계 안에서 값만 오가는 것은 풀린 것이 아니다. 알림이 한 번뿐인지 본다.
    func test_movingInsideRedStaysQuiet() {
        var watch = RecoveryWatch()
        for used in [95, 97, 99, 100] {
            XCTAssertTrue(watch.step([org([.session: limit(used)])]).isEmpty)
        }
        XCTAssertEqual(watch.step([org([.session: limit(60)])]).map(\.uuid), ["u1"])
    }

    /// 읽기가 실패한 계정은 기억을 건드리지 않는다. 지우면 풀릴 때 알릴 근거가
    /// 사라지고, 풀렸다고 보면 거짓말이 된다.
    func test_staleReadingKeepsMemory() {
        var watch = RecoveryWatch()
        _ = watch.step([org([.session: limit(97)])])
        XCTAssertTrue(watch.step([org([.session: limit(97)], isStale: true)]).isEmpty)
        XCTAssertEqual(watch.watching, ["u1"])
        XCTAssertEqual(watch.step([org([.session: limit(10)])]).map(\.uuid), ["u1"])
    }

    /// 값을 하나도 못 읽은 계정도 마찬가지다.
    func test_unreadableOrgIsIgnored() {
        var watch = RecoveryWatch()
        _ = watch.step([org([.session: limit(97)])])
        XCTAssertTrue(watch.step([org([:])]).isEmpty)
        XCTAssertEqual(watch.watching, ["u1"])
    }

    /// 계정마다 따로 센다. 하나가 풀려도 다른 하나의 기억은 남는다.
    func test_accountsAreIndependent() {
        var watch = RecoveryWatch()
        _ = watch.step([org([.session: limit(97)], uuid: "a"),
                        org([.session: limit(100)], uuid: "b")])
        let out = watch.step([org([.session: limit(10)], uuid: "a"),
                              org([.session: limit(100)], uuid: "b")])
        XCTAssertEqual(out.map(\.uuid), ["a"])
        XCTAssertEqual(watch.watching, ["b"])
    }

    /// seed 는 기억만 하고 알리지 않는다. 앱을 켠 직후 첫 읽기가 이걸 쓴다.
    func test_seedRemembersWithoutNotifying() {
        var watch = RecoveryWatch()
        watch.seed([org([.session: limit(97)])])
        XCTAssertEqual(watch.watching, ["u1"])
        // 켤 때 이미 빨강이었어도 풀리면 알린다
        XCTAssertEqual(watch.step([org([.session: limit(10)])]).map(\.uuid), ["u1"])
    }

    /// Enterprise 는 시간 창이 없다. 월 예산으로 같은 판단을 한다.
    func test_budgetOrgUsesSpend() {
        var watch = RecoveryWatch()
        _ = watch.step([spendOrg(96)])
        XCTAssertEqual(watch.watching, ["e1"])
        XCTAssertEqual(watch.step([spendOrg(40)]).map(\.uuid), ["e1"])
    }
}
