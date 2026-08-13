import XCTest
@testable import ClfDesktop

/// 상태 한 줄과 색. 창은 이 결과를 그대로 그린다.
final class AutoResumeStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAccents() {
        XCTAssertEqual(AutoResumeStatus.off.accent, .none)
        XCTAssertEqual(AutoResumeStatus.watching.accent, .good)
        XCTAssertEqual(AutoResumeStatus.ran(now).accent, .good)
        XCTAssertEqual(AutoResumeStatus.scheduled(now).accent, .wait)
        XCTAssertEqual(AutoResumeStatus.running.accent, .wait)
        // 규칙대로 안 돈 것과 깨진 것은 뜻이 다르지만 둘 다 눈에 걸려야 한다
        XCTAssertEqual(AutoResumeStatus.held("주간 전체 잔여가 3% 라").accent, .bad)
        XCTAssertEqual(AutoResumeStatus.failed("exit 1").accent, .bad)
    }

    func testScheduledSpeaksRelativeTime() {
        let text = AutoResumeStatus.scheduled(now.addingTimeInterval(2 * 3600 + 840))
            .text(now: now)
        XCTAssertTrue(text.contains("2시간 14분 뒤에 재개합니다"), text)
        XCTAssertTrue(text.contains("잔여를 다시 확인"), text)
    }

    /// 며칠 뒤 리셋도 그대로 말한다. 시계만 적으면 오늘로 읽힌다.
    func testScheduledDaysAhead() {
        let text = AutoResumeStatus.scheduled(now.addingTimeInterval(3 * 86_400)).text(now: now)
        XCTAssertTrue(text.contains("3일 뒤에 재개합니다"), text)
    }

    /// 예약 시각이 지나 새 사용량을 기다리는 동안. `지남에 재개합니다` 가 되면 안 된다.
    func testScheduledPastDueReadsAsSoon() {
        let text = AutoResumeStatus.scheduled(now.addingTimeInterval(-30)).text(now: now)
        XCTAssertTrue(text.contains("곧 재개합니다"), text)
        XCTAssertFalse(text.contains("지남"), text)
    }

    func testRanAttachesParticleOnlyWhenNeeded() {
        XCTAssertTrue(AutoResumeStatus.ran(now.addingTimeInterval(-300)).text(now: now)
            .hasPrefix("5분 전에 이어 돌렸습니다"))
        XCTAssertTrue(AutoResumeStatus.ran(now.addingTimeInterval(-10)).text(now: now)
            .hasPrefix("방금 이어 돌렸습니다"))
        XCTAssertTrue(AutoResumeStatus.ran(now.addingTimeInterval(-100_000)).text(now: now)
            .hasPrefix("어제 이어 돌렸습니다"))
    }

    /// 보류 문구는 판정이 만든 이유를 그대로 담고 다음을 약속한다.
    func testHeldKeepsTheReason() {
        let text = AutoResumeStatus.held("주간 전체 잔여가 3% 라 이번 리셋에는 재개하지 않았습니다")
            .text(now: now)
        XCTAssertTrue(text.contains("주간 전체 잔여가 3%"), text)
        XCTAssertTrue(text.contains("다음 리셋"), text)
    }

    /// 어디를 찾아봤는지 적어야 다른 데 설치한 사람이 알 수 있다.
    func testUnavailableListsSearchedPaths() {
        let text = AutoResumeStatus.unavailable(["/a/claude", "/b/claude"]).text(now: now)
        XCTAssertTrue(text.contains("/a/claude"), text)
        XCTAssertTrue(text.contains("/b/claude"), text)
    }

    func testOffExplainsWhatTurningItOnDoes() {
        XCTAssertTrue(AutoResumeStatus.off.text(now: now).contains("켜면"))
    }
}
