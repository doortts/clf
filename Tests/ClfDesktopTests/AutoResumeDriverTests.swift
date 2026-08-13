import XCTest
@testable import ClfDesktop

/// 판정과 실행을 잇는 자리. 진짜 CLI 대신 흉내 낸 스크립트를 쓴다.
///
/// 이 검증이 가능한 것 자체가 이 타입을 메뉴바 모델에서 떼어 낸 이유다.
/// 사용량 읽기와 막대 그리기에 붙어 있으면 AppKit 없이 한 줄도 못 돌린다.
final class AutoResumeDriverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resume-driver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func script(_ body: String) throws -> URL {
        let url = dir.appendingPathComponent("fake-claude-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url
    }

    private func plan() -> AutoResumePlan {
        AutoResumePlan(orgUUID: "u", sessionID: "sid", cwd: "", title: "제목")
    }

    private func org(session: (Int, Date?)? = nil, weekly: (Int, Date?)? = nil) -> OrgUsage {
        var limits: [LimitKind: UsageLimit] = [:]
        if let session {
            limits[.session] = UsageLimit(percentUsed: 100 - session.0,
                                          resetsAt: session.1, severity: "")
        }
        if let weekly {
            limits[.weeklyAll] = UsageLimit(percentUsed: 100 - weekly.0,
                                            resetsAt: weekly.1, severity: "")
        }
        return OrgUsage(uuid: "u", name: "TEAM", isActive: true, plan: nil,
                        limits: limits, isStale: false)
    }

    // MARK: 상태

    /// CLI 가 없으면 켜 봐야 돌릴 수단이 없다. 어디를 찾아봤는지 그대로 말한다.
    @MainActor
    func testWithoutCliItSaysWhereItLooked() {
        let driver = AutoResumeDriver(executable: nil, post: Sink().post)
        XCTAssertFalse(driver.canRun)
        XCTAssertEqual(driver.status, .unavailable(ClaudeCLI.candidates()))
    }

    @MainActor
    func testNoPlanIsOff() throws {
        let driver = AutoResumeDriver(executable: try script("exit 0"), post: Sink().post)
        XCTAssertEqual(driver.status, .off)
    }

    /// 체크는 켜져 있는데 저장할 것이 없는 상태. 꺼졌다고 말하면 화면과 어긋난다.
    @MainActor
    func testTurningItOnWithoutASessionAsksForOne() throws {
        let driver = AutoResumeDriver(executable: try script("exit 0"), post: Sink().post)
        driver.planChanged(nil, pending: true)
        XCTAssertEqual(driver.status, .needsSession)
    }

    @MainActor
    func testPickingASessionStartsWatching() throws {
        let driver = AutoResumeDriver(executable: try script("exit 0"), post: Sink().post)
        driver.planChanged(nil, pending: true)
        driver.planChanged(plan(), pending: false)
        XCTAssertEqual(driver.status, .watching)
        XCTAssertEqual(driver.watchedUUID, "u")
    }

    @MainActor
    func testExhaustionShowsTheScheduledTime() throws {
        let driver = AutoResumeDriver(executable: try script("exit 0"), post: Sink().post)
        driver.planChanged(plan(), pending: false)
        let reset = now.addingTimeInterval(3600)
        driver.step(org: org(session: (0, reset), weekly: (60, nil)), readAt: now, now: now)
        XCTAssertEqual(driver.status, .scheduled(reset.addingTimeInterval(180)))
        XCTAssertTrue(driver.isDue(now: reset.addingTimeInterval(180)))
    }

    /// 끄면 걸려 있던 예약도 같이 놓는다. 남겨 두면 부르는 쪽이 판정할 때가
    /// 됐다고 매분 사용량을 다시 읽는다.
    @MainActor
    func testTurningItOffDropsTheSchedule() throws {
        let driver = AutoResumeDriver(executable: try script("exit 0"), post: Sink().post)
        driver.planChanged(plan(), pending: false)
        let reset = now.addingTimeInterval(3600)
        driver.step(org: org(session: (0, reset), weekly: (60, nil)), readAt: now, now: now)

        driver.planChanged(nil, pending: true)
        XCTAssertEqual(driver.status, .needsSession)
        XCTAssertFalse(driver.isDue(now: reset.addingTimeInterval(3600)))
    }

    // MARK: 판정과 실행

    /// 마지막 남은 몫은 사람이 쓸 자리다. 안 돌린 이유는 알림으로도 나간다.
    @MainActor
    func testHoldingTellsTheReason() async throws {
        let sink = Sink()
        let driver = AutoResumeDriver(executable: try script("exit 0"), post: sink.post)
        driver.planChanged(plan(), pending: false)
        let reset = now.addingTimeInterval(3600)
        driver.step(org: org(session: (0, reset), weekly: (30, nil)), readAt: now, now: now)

        let due = reset.addingTimeInterval(180)
        driver.step(org: org(session: (100, nil), weekly: (3, nil)), readAt: due, now: due)
        guard case .held(let why) = driver.status else {
            return XCTFail("보류여야 한다: \(driver.status)")
        }
        XCTAssertTrue(why.contains("3%"), why)

        await fulfillment(of: [sink.arrived], timeout: 5)
        XCTAssertEqual(sink.events.first?.title, "자동 재개 보류")
    }

    @MainActor
    func testRunningReportsTheResult() async throws {
        let sink = Sink()
        let driver = AutoResumeDriver(executable: try script("exit 0"), post: sink.post)
        driver.planChanged(plan(), pending: false)
        let reset = now.addingTimeInterval(3600)
        driver.step(org: org(session: (0, reset), weekly: (60, nil)), readAt: now, now: now)

        let due = reset.addingTimeInterval(180)
        driver.step(org: org(session: (100, nil), weekly: (60, nil)), readAt: due, now: due)
        XCTAssertEqual(driver.status, .running)

        await fulfillment(of: [sink.arrived], timeout: 10)
        guard case .ran = driver.status else {
            return XCTFail("돌린 것으로 남아야 한다: \(driver.status)")
        }
        XCTAssertEqual(sink.events.first?.title, "세션 자동 재개")
        // 무엇을 이어 돌렸는지 본문에 남는다. 알림만 보고도 알아야 한다
        XCTAssertEqual(sink.events.first?.body, "제목 세션을 이어서 실행했습니다")
    }

    @MainActor
    func testFailureCarriesTheExitCode() async throws {
        let sink = Sink()
        let driver = AutoResumeDriver(executable: try script("exit 3"), post: sink.post)
        driver.planChanged(plan(), pending: false)
        let reset = now.addingTimeInterval(3600)
        driver.step(org: org(session: (0, reset), weekly: (60, nil)), readAt: now, now: now)
        let due = reset.addingTimeInterval(180)
        driver.step(org: org(session: (100, nil), weekly: (60, nil)), readAt: due, now: due)

        await fulfillment(of: [sink.arrived], timeout: 10)
        guard case .failed(let detail) = driver.status else {
            return XCTFail("실패로 남아야 한다: \(driver.status)")
        }
        XCTAssertTrue(detail.contains("exit 3"), detail)
    }

    /// 한 세션에 둘이 붙으면 같은 자리에서 두 대화가 엇갈려 쓰인다. 도는 동안
    /// 새 소진이 보고돼도 예약도 판정도 하지 않는다.
    @MainActor
    func testDoesNotStartASecondRunWhileOneIsInFlight() async throws {
        let log = dir.appendingPathComponent("count")
        let sink = Sink()
        let cli = try script("echo x >> \"\(log.path)\"\nsleep 1")
        let driver = AutoResumeDriver(executable: cli, post: sink.post)
        driver.planChanged(plan(), pending: false)

        let reset = now.addingTimeInterval(3600)
        driver.step(org: org(session: (0, reset), weekly: (60, nil)), readAt: now, now: now)
        let due = reset.addingTimeInterval(180)
        driver.step(org: org(session: (100, nil), weekly: (60, nil)), readAt: due, now: due)
        XCTAssertEqual(driver.status, .running)

        // 다음 소진과 그 리셋까지 지나가도, 도는 중이면 손대지 않는다
        let next = due.addingTimeInterval(60)
        driver.step(org: org(session: (0, next), weekly: (60, nil)), readAt: next, now: next)
        let after = next.addingTimeInterval(300)
        driver.step(org: org(session: (100, nil), weekly: (60, nil)), readAt: after, now: after)
        XCTAssertEqual(driver.status, .running)

        await fulfillment(of: [sink.arrived], timeout: 10)
        let ran = String(decoding: try Data(contentsOf: log), as: UTF8.self)
        XCTAssertEqual(ran, "x\n", "한 번만 돌아야 한다")
    }
}

/// 알림 문 대신 여기에 쌓는다. 드라이버는 `Notifier` 를 모른다.
@MainActor
private final class Sink {
    var events: [UsageEvent] = []
    let arrived = XCTestExpectation(description: "자동 재개 알림")

    func post(_ event: UsageEvent) async {
        events.append(event)
        arrived.fulfill()
    }
}
