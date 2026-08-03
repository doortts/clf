import XCTest
@testable import ClfDesktop

private func limit(_ used: Int) -> UsageLimit {
    UsageLimit(percentUsed: used, resetsAt: nil, severity: "normal")
}
private func org(_ uuid: String, _ used: Int?, error: String? = nil,
                 stale: Bool = false) -> OrgUsage {
    OrgUsage(uuid: uuid, name: uuid.uppercased(), isActive: false, plan: "team",
             limits: used.map { [.session: limit($0)] } ?? [:],
             error: error, isStale: stale)
}

/// 언제 다시 읽어도 되는지.
///
/// 팝오버를 열 때마다 읽으면 몇 번 여닫는 것으로 429 가 온다. 실제로 그랬다.
final class ReadGateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func test_firstReadIsAlwaysAllowed() {
        var gate = ReadGate()
        XCTAssertTrue(gate.allows(at: t0))
    }

    /// 곧바로 다시 열면 안 읽는다. 화면에는 방금 읽은 값이 이미 있다.
    func test_secondReadTooSoonIsRefused() {
        var gate = ReadGate()
        gate.record(at: t0, throttled: false)
        XCTAssertFalse(gate.allows(at: t0.addingTimeInterval(5)))
        XCTAssertFalse(gate.allows(at: t0.addingTimeInterval(ReadGate.quietWindow - 1)))
    }

    func test_readAllowedAfterQuietWindow() {
        var gate = ReadGate()
        gate.record(at: t0, throttled: false)
        XCTAssertTrue(gate.allows(at: t0.addingTimeInterval(ReadGate.quietWindow)))
    }

    /// 429 를 받았으면 훨씬 오래 쉰다. 여기서 더 두드리면 창이 안 열린다.
    func test_throttledWaitsMuchLonger() {
        var gate = ReadGate()
        gate.record(at: t0, throttled: true)
        XCTAssertFalse(gate.allows(at: t0.addingTimeInterval(ReadGate.quietWindow + 1)))
        XCTAssertTrue(gate.allows(at: t0.addingTimeInterval(ReadGate.throttledWindow)))
    }

    /// 얼마나 더 기다려야 하는지 말할 수 있어야 한다. 눌러도 아무 일이 없으면
    /// 고장 난 것으로 보인다.
    func test_reportsWhenTheNextReadIsAllowed() {
        var gate = ReadGate()
        gate.record(at: t0, throttled: true)
        XCTAssertEqual(gate.nextAllowed, t0.addingTimeInterval(ReadGate.throttledWindow))
    }

    /// 주기 루프는 자기 시계를 따른다. 문을 통과해야 하면 두 개가 싸운다.
    func test_scheduledReadIgnoresTheGate() {
        var gate = ReadGate()
        gate.record(at: t0, throttled: false)
        XCTAssertTrue(gate.allows(at: t0.addingTimeInterval(1), scheduled: true))
    }

    /// 429 일 때는 주기 루프도 막는다. 서버가 그만 물어보라고 한 것이다.
    func test_throttlingStopsEvenScheduledReads() {
        var gate = ReadGate()
        gate.record(at: t0, throttled: true)
        XCTAssertFalse(gate.allows(at: t0.addingTimeInterval(60), scheduled: true))
    }
}

/// 실패해도 알던 값을 지우지 않는다.
final class StaleMergeTests: XCTestCase {

    /// 이것이 "아무것도 안 보인다" 의 원인이었다. 한 조직이 429 를 맞으면
    /// 빈 limits 로 갈아치워서 방금까지 보이던 숫자가 사라졌다.
    func test_failedOrgKeepsItsLastNumbers() {
        let before = [org("a", 40)]
        let after = mergeKeepingLastGood(fresh: [org("a", nil, error: "요청이 너무 잦다")],
                                         previous: before)
        XCTAssertEqual(after[0].limits[.session]?.percentUsed, 40)
        XCTAssertTrue(after[0].isStale)
        // 왜 못 읽었는지도 남긴다. 값만 남기면 사용자가 옛 값을 지금 값으로 믿는다
        XCTAssertEqual(after[0].error, "요청이 너무 잦다")
    }

    func test_successfulOrgTakesTheNewNumbers() {
        let after = mergeKeepingLastGood(fresh: [org("a", 55)], previous: [org("a", 40)])
        XCTAssertEqual(after[0].limits[.session]?.percentUsed, 55)
        XCTAssertFalse(after[0].isStale)
    }

    /// 처음부터 못 읽은 조직은 보여줄 옛 값이 없다.
    func test_neverReadOrgStaysEmpty() {
        let after = mergeKeepingLastGood(fresh: [org("a", nil, error: "토큰 없음")], previous: [])
        XCTAssertTrue(after[0].limits.isEmpty)
        XCTAssertFalse(after[0].isStale)
    }

    /// 한 번 낡았다가 다시 읽히면 낡음이 풀린다.
    func test_recoveryClearsStale() {
        let stale = mergeKeepingLastGood(fresh: [org("a", nil, error: "x")],
                                         previous: [org("a", 40)])
        let fresh = mergeKeepingLastGood(fresh: [org("a", 60)], previous: stale)
        XCTAssertFalse(fresh[0].isStale)
        XCTAssertNil(fresh[0].error)
    }

    /// 낡은 값을 또 물려준다. 429 가 길어져도 숫자가 계속 보여야 한다.
    func test_stalenessCarriesForward() {
        var current = [org("a", 40)]
        for _ in 0..<3 {
            current = mergeKeepingLastGood(fresh: [org("a", nil, error: "x")], previous: current)
        }
        XCTAssertEqual(current[0].limits[.session]?.percentUsed, 40)
        XCTAssertTrue(current[0].isStale)
    }

    func test_orgsThatVanishAreNotResurrected() {
        let after = mergeKeepingLastGood(fresh: [org("b", 10)], previous: [org("a", 40)])
        XCTAssertEqual(after.map(\.uuid), ["b"])
    }
}

/// 왜 안 읽었는지 말할 때와 조용히 넘어갈 때.
final class GateSilenceTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 방금 읽어서 안 읽은 것은 사용자가 알 일이 아니다. 화면에는 방금 값이
    /// 이미 있고, "요청이 몰렸다" 는 말은 사실도 아니다.
    func test_quietWindowSaysNothing() {
        var gate = ReadGate()
        gate.record(at: t0, throttled: false)
        XCTAssertNil(gate.complaint(at: t0.addingTimeInterval(5)))
    }

    /// 429 는 말해야 한다. 값이 낡은 채로 멈춰 있는 이유다.
    func test_throttleExplainsItself() {
        var gate = ReadGate()
        gate.record(at: t0, throttled: true)
        let text = try? XCTUnwrap(gate.complaint(at: t0.addingTimeInterval(60)))
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("분"), text!)
    }

    func test_nothingToSayOnceItClears() {
        var gate = ReadGate()
        gate.record(at: t0, throttled: true)
        XCTAssertNil(gate.complaint(at: t0.addingTimeInterval(ReadGate.throttledWindow)))
    }
}
