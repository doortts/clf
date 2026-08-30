import XCTest
@testable import ClfDesktop

private func limit(_ used: Int) -> UsageLimit {
    UsageLimit(percentUsed: used, resetsAt: nil, severity: "normal")
}

/// 회선이 끊긴 읽기는 429 와 반대로 다룬다.
///
/// 실측으로 만났다. 끊긴 채로 팝오버를 열면 카드에 `-1009` 가 뜨는데, 회선을
/// 되살려도 화면이 그대로였다. 주기는 5분을 쉬고 새로고침은 정숙 구간 1분에
/// 걸려 조용히 무시돼서, 사용자가 할 수 있는 일이 기다리는 것뿐이었다.
final class OfflineRecoveryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func offline() -> DesktopSnapshot {
        DesktopSnapshot(
            orgs: [OrgUsage(uuid: "a", name: "A", isActive: true, plan: "team",
                            limits: [:], error: UsageFetchError.noNetwork.description)],
            unreadable: [], offline: true, readAt: Date())
    }
    private func ok(_ used: Int) -> DesktopSnapshot {
        DesktopSnapshot(
            orgs: [OrgUsage(uuid: "a", name: "A", isActive: true, plan: "team",
                            limits: [.session: limit(used)])],
            unreadable: [], readAt: Date())
    }

    /// 서버가 막은 것이 아니라 요청이 나가지도 못한 것이다. 짧게 쉰다.
    func test_offlineRetriesQuickly() {
        var pacer = RefreshPacer()
        _ = pacer.observe(ok(10))
        XCTAssertEqual(pacer.observe(offline()), RefreshPacer.offlineInterval)
        XCTAssertLessThan(RefreshPacer.offlineInterval, RefreshPacer.activeInterval)
    }

    /// 루프는 `observe` 가 준 값이 아니라 `currentInterval` 을 보고 잔다.
    func test_offlineShowsUpInTheCurrentInterval() {
        var pacer = RefreshPacer()
        _ = pacer.observe(offline())
        XCTAssertEqual(pacer.currentInterval, RefreshPacer.offlineInterval)
    }

    /// 끊긴 채로 값이 그대로인 것은 조용한 게 아니다. 여기서 10분으로 늘리면
    /// 회선이 돌아와도 그만큼 늦게 알아차린다.
    func test_stayingOfflineNeverCountsAsIdle() {
        var pacer = RefreshPacer()
        for _ in 0..<5 { _ = pacer.observe(offline()) }
        XCTAssertEqual(pacer.idleStreak, 0)
        XCTAssertEqual(pacer.currentInterval, RefreshPacer.offlineInterval)
    }

    /// 회선이 돌아오면 곧바로 제 주기로 돌아온다.
    func test_recoversOnTheNextGoodRead() {
        var pacer = RefreshPacer()
        for _ in 0..<5 { _ = pacer.observe(offline()) }
        XCTAssertEqual(pacer.observe(ok(10)), RefreshPacer.activeInterval)
    }

    /// 429 가 이긴다. 한쪽 계정이 끊겨도 서버가 그만 물어보라고 했으면 그쪽을
    /// 따른다. 여기서 30초로 두드리면 창이 안 열린다.
    func test_throttlingWinsOverOffline() {
        var pacer = RefreshPacer()
        let both = DesktopSnapshot(orgs: offline().orgs, unreadable: [],
                                   throttled: true, offline: true, readAt: Date())
        XCTAssertEqual(pacer.observe(both), RefreshPacer.throttledInterval)
    }

    /// 이것이 "회선을 되살려도 그대로" 의 원인이었다. 정숙 구간은 방금 읽은
    /// 값을 지키자고 있는 것인데, 못 읽은 읽기에는 지킬 값이 없다.
    func test_failedReadLeavesTheGateOpen() {
        var gate = ReadGate()
        gate.record(at: t0, throttled: false, offline: true)
        XCTAssertTrue(gate.allows(at: t0.addingTimeInterval(1)))
    }

    /// 읽고 나면 문은 다시 닫힌다. 끊겼던 것이 면제권이 되면 안 된다.
    func test_gateClosesAgainOnceItReads() {
        var gate = ReadGate()
        gate.record(at: t0, throttled: false, offline: true)
        gate.record(at: t0.addingTimeInterval(30), throttled: false)
        XCTAssertFalse(gate.allows(at: t0.addingTimeInterval(31)))
    }

    /// 429 는 끊김보다 세다. 문을 열어 주지 않는다.
    func test_throttledStaysShutEvenIfSomethingWasOffline() {
        var gate = ReadGate()
        gate.record(at: t0, throttled: true, offline: true)
        XCTAssertFalse(gate.allows(at: t0.addingTimeInterval(60), scheduled: true))
    }
}
