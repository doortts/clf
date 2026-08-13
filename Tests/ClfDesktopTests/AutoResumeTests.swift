import XCTest
@testable import ClfDesktop

/// 자동 재개 판정. 시각과 사용량을 주입해 통째로 본다.
final class AutoResumeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func org(session: (Int, Date?)? = nil,
                     weekly: (Int, Date?)? = nil,
                     scoped: (Int, Date?)? = nil,
                     stale: Bool = false) -> OrgUsage {
        var limits: [LimitKind: UsageLimit] = [:]
        if let session {
            limits[.session] = UsageLimit(percentUsed: 100 - session.0,
                                          resetsAt: session.1, severity: "")
        }
        if let weekly {
            limits[.weeklyAll] = UsageLimit(percentUsed: 100 - weekly.0,
                                            resetsAt: weekly.1, severity: "")
        }
        if let scoped {
            limits[.weeklyScoped] = UsageLimit(percentUsed: 100 - scoped.0,
                                               resetsAt: scoped.1, severity: "")
        }
        return OrgUsage(uuid: "u", name: "TEAM", isActive: true, plan: nil,
                        limits: limits, isStale: stale)
    }

    // MARK: 예약

    func testAmpleAccountSchedulesNothing() {
        var watch = AutoResumeWatch()
        let action = watch.step(org(session: (80, nil), weekly: (60, nil)),
                               now: now, readAt: now)
        XCTAssertEqual(action, .none)
        XCTAssertNil(watch.scheduledAt)
    }

    func testExhaustedSessionSchedulesThreeMinutesAfterReset() {
        var watch = AutoResumeWatch()
        let reset = now.addingTimeInterval(3600)
        _ = watch.step(org(session: (0, reset), weekly: (60, nil)), now: now, readAt: now)
        XCTAssertEqual(watch.scheduledAt, reset.addingTimeInterval(180))
        XCTAssertFalse(watch.isDue(now))
    }

    /// 5시간과 주간이 같이 소진이면 늦게 풀리는 쪽이 실제로 막고 있다.
    func testSchedulesOnTheLaterResetWhenBothExhausted() {
        var watch = AutoResumeWatch()
        let soon = now.addingTimeInterval(3600)
        let later = now.addingTimeInterval(86_400)
        _ = watch.step(org(session: (0, soon), weekly: (0, later)), now: now, readAt: now)
        XCTAssertEqual(watch.scheduledAt, later.addingTimeInterval(180))
    }

    /// 모델 하나에만 걸리는 창은 재개를 막지 않는다.
    func testScopedWeeklyAloneDoesNotSchedule() {
        var watch = AutoResumeWatch()
        _ = watch.step(org(session: (50, nil), weekly: (40, nil),
                           scoped: (0, now.addingTimeInterval(3600))),
                       now: now, readAt: now)
        XCTAssertNil(watch.scheduledAt)
    }

    /// 언제 풀릴지 모르는 창은 기다릴 수 없다. 지어낸 시각으로 예약하면
    /// 그 시점에 아직 소진인 창을 보고 그 리셋을 통째로 건너뛴다.
    func testExhaustedWindowWithoutResetTimeDoesNotSchedule() {
        var watch = AutoResumeWatch()
        _ = watch.step(org(session: (0, nil), weekly: (60, nil)), now: now, readAt: now)
        XCTAssertNil(watch.scheduledAt)
    }

    func testStaleReadDoesNotSchedule() {
        var watch = AutoResumeWatch()
        _ = watch.step(org(session: (0, now.addingTimeInterval(3600)), stale: true),
                       now: now, readAt: now)
        XCTAssertNil(watch.scheduledAt)
    }

    // MARK: 판정

    func testRunsWhenBothWindowsHaveRoom() {
        var watch = AutoResumeWatch()
        let reset = now.addingTimeInterval(3600)
        _ = watch.step(org(session: (0, reset), weekly: (60, nil)), now: now, readAt: now)

        let due = reset.addingTimeInterval(180)
        XCTAssertTrue(watch.isDue(due))
        XCTAssertEqual(watch.step(org(session: (100, nil), weekly: (60, nil)),
                                 now: due, readAt: due), .run)
        XCTAssertNil(watch.scheduledAt)
    }

    /// 5시간은 리셋으로 풀렸지만 주간이 바닥이다. 마지막 남은 몫은 사람 자리다.
    func testHoldsWhenWeeklyIsBelowThreshold() {
        var watch = AutoResumeWatch()
        let reset = now.addingTimeInterval(3600)
        _ = watch.step(org(session: (0, reset), weekly: (30, nil)), now: now, readAt: now)

        let due = reset.addingTimeInterval(180)
        let action = watch.step(org(session: (100, nil), weekly: (3, nil)),
                                now: due, readAt: due)
        guard case .hold(let why) = action else { return XCTFail("보류여야 한다: \(action)") }
        XCTAssertTrue(why.contains("주간 전체"), why)
        XCTAssertTrue(why.contains("3%"), why)
    }

    /// 경계는 포함이다. 5% 남았으면 돈다.
    func testThresholdIsInclusive() {
        var watch = AutoResumeWatch()
        let reset = now.addingTimeInterval(3600)
        _ = watch.step(org(session: (0, reset), weekly: (50, nil)), now: now, readAt: now)
        let due = reset.addingTimeInterval(180)
        XCTAssertEqual(watch.step(org(session: (5, nil), weekly: (5, nil)),
                                 now: due, readAt: due), .run)
    }

    /// 플랜에 없는 창을 0% 로 치면 그 계정은 영영 못 돈다.
    func testMissingWindowDoesNotBlock() {
        var watch = AutoResumeWatch()
        let reset = now.addingTimeInterval(3600)
        _ = watch.step(org(session: (0, reset)), now: now, readAt: now)
        let due = reset.addingTimeInterval(180)
        XCTAssertEqual(watch.step(org(session: (90, nil)), now: due, readAt: due), .run)
    }

    // MARK: 낡은 값

    /// 리셋 직전에 읽은 값은 0% 다. 그걸로 판정하면 방금 풀린 창을 보고 보류한다.
    func testDueWithStaleNumbersWaitsInsteadOfDeciding() {
        var watch = AutoResumeWatch()
        let reset = now.addingTimeInterval(3600)
        _ = watch.step(org(session: (0, reset), weekly: (60, nil)), now: now, readAt: now)

        let due = reset.addingTimeInterval(180)
        // 10분 전에 읽은 값. 그때는 아직 0% 였다
        let action = watch.step(org(session: (0, reset), weekly: (60, nil)),
                                now: due, readAt: due.addingTimeInterval(-600))
        XCTAssertEqual(action, .none)
        XCTAssertNotNil(watch.scheduledAt, "예약은 그대로 둬야 다음 읽기에 판정한다")

        // 새로 읽어오면 그때 판정한다
        XCTAssertEqual(watch.step(org(session: (100, nil), weekly: (60, nil)),
                                 now: due, readAt: due), .run)
    }

    func testNeverReadYetWaits() {
        var watch = AutoResumeWatch()
        let reset = now.addingTimeInterval(3600)
        _ = watch.step(org(session: (0, reset), weekly: (60, nil)), now: now, readAt: now)
        let due = reset.addingTimeInterval(180)
        XCTAssertEqual(watch.step(org(session: (100, nil)), now: due, readAt: nil), .none)
        XCTAssertNotNil(watch.scheduledAt)
    }

    // MARK: 두 번 돌지 않는다

    func testSameResetIsNotScheduledTwice() {
        var watch = AutoResumeWatch()
        let reset = now.addingTimeInterval(3600)
        _ = watch.step(org(session: (0, reset), weekly: (30, nil)), now: now, readAt: now)
        let due = reset.addingTimeInterval(180)
        // 주간이 바닥이라 보류했다
        _ = watch.step(org(session: (100, nil), weekly: (3, nil)), now: due, readAt: due)

        // 5시간 창이 아직 같은 리셋 시각으로 소진이라 보고돼도 다시 예약하지 않는다
        _ = watch.step(org(session: (0, reset), weekly: (3, nil)),
                       now: due.addingTimeInterval(60), readAt: due.addingTimeInterval(60))
        XCTAssertNil(watch.scheduledAt)
    }

    /// 초 단위로 흔들리는 값이라 같은 리셋인지는 분 단위로 본다.
    func testJitteredSameResetIsNotScheduledTwice() {
        var watch = AutoResumeWatch()
        let reset = now.addingTimeInterval(3600)
        _ = watch.step(org(session: (0, reset), weekly: (30, nil)), now: now, readAt: now)
        let due = reset.addingTimeInterval(180)
        _ = watch.step(org(session: (100, nil), weekly: (3, nil)), now: due, readAt: due)

        let jittered = reset.addingTimeInterval(-1)
        _ = watch.step(org(session: (0, jittered), weekly: (3, nil)),
                       now: due.addingTimeInterval(60), readAt: due.addingTimeInterval(60))
        XCTAssertNil(watch.scheduledAt)
    }

    /// 다음 창이 새로 소진되면 그때는 다시 예약한다.
    func testNextExhaustionSchedulesAgain() {
        var watch = AutoResumeWatch()
        let reset = now.addingTimeInterval(3600)
        _ = watch.step(org(session: (0, reset), weekly: (60, nil)), now: now, readAt: now)
        let due = reset.addingTimeInterval(180)
        XCTAssertEqual(watch.step(org(session: (100, nil), weekly: (60, nil)),
                                 now: due, readAt: due), .run)

        let next = due.addingTimeInterval(5 * 3600)
        _ = watch.step(org(session: (0, next), weekly: (60, nil)),
                       now: due.addingTimeInterval(600), readAt: due.addingTimeInterval(600))
        XCTAssertEqual(watch.scheduledAt, next.addingTimeInterval(180))
    }

    func testForgetClearsSchedule() {
        var watch = AutoResumeWatch()
        _ = watch.step(org(session: (0, now.addingTimeInterval(3600))), now: now, readAt: now)
        XCTAssertNotNil(watch.scheduledAt)
        watch.forget()
        XCTAssertNil(watch.scheduledAt)
    }

    func testMissingAccountDoesNothing() {
        var watch = AutoResumeWatch()
        XCTAssertEqual(watch.step(nil, now: now, readAt: now), .none)
        XCTAssertNil(watch.scheduledAt)
    }

    /// 계정이 목록에서 사라지면 예약을 놓는다. 들고 있으면 부르는 쪽이 판정할
    /// 때가 됐다고 매분 사용량을 다시 읽는다.
    func testDisappearedAccountDropsTheSchedule() {
        var watch = AutoResumeWatch()
        _ = watch.step(org(session: (0, now.addingTimeInterval(3600))), now: now, readAt: now)
        XCTAssertNotNil(watch.scheduledAt)

        _ = watch.step(nil, now: now.addingTimeInterval(60), readAt: now.addingTimeInterval(60))
        XCTAssertNil(watch.scheduledAt)
    }

    /// 계정이 돌아오고 그때도 소진이면 다시 예약한다.
    func testAccountComingBackSchedulesAgain() {
        var watch = AutoResumeWatch()
        let reset = now.addingTimeInterval(3600)
        _ = watch.step(org(session: (0, reset)), now: now, readAt: now)
        _ = watch.step(nil, now: now, readAt: now)
        _ = watch.step(org(session: (0, reset)), now: now, readAt: now)
        XCTAssertEqual(watch.scheduledAt, reset.addingTimeInterval(180))
    }
}
