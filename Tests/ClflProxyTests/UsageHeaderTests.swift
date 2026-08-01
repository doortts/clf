import XCTest
import ClflCore
@testable import ClflProxy

/// 응답 헤더에서 읽어내는 사용량. Usage API 를 못 부르는 자격증명에서는
/// 이것이 유일한 관측 경로다. docs/design/02-domain-model.md 2절
final class RateLimitHeaderTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func bag(_ pairs: [String: String]) -> HeaderBag {
        var b = HeaderBag()
        for (k, v) in pairs { b[k] = v }
        return b
    }

    func test_readsUnifiedFiveHourWindow() {
        let s = rateLimitSnapshot(from: bag([
            "anthropic-ratelimit-unified-5h-status": "allowed",
            "anthropic-ratelimit-unified-5h-remaining": "37",
            "anthropic-ratelimit-unified-5h-reset": "1700003600",
        ]), now: now)
        XCTAssertEqual(s?.fiveHour?.usedRatio ?? -1, 0.63, accuracy: 1e-9)
        XCTAssertEqual(s?.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_700_003_600))
    }

    func test_readsSevenDayWindow() {
        let s = rateLimitSnapshot(from: bag([
            "anthropic-ratelimit-unified-7d-remaining": "80",
            "anthropic-ratelimit-unified-7d-reset": "1700600000",
        ]), now: now)
        XCTAssertEqual(s?.sevenDayAll?.usedRatio ?? -1, 0.20, accuracy: 1e-9)
    }

    /// 헤더는 조직 전체만 말한다. 모델별 주간은 Usage API 에만 있다.
    func test_headersNeverFillModelWeekly() {
        let s = rateLimitSnapshot(from: bag([
            "anthropic-ratelimit-unified-5h-remaining": "50",
            "anthropic-ratelimit-unified-5h-reset": "1700003600",
        ]), now: now)
        XCTAssertTrue(s?.modelWeekly.isEmpty ?? false)
        XCTAssertEqual(s?.source, .headers)
    }

    /// 관련 헤더가 하나도 없으면 스냅샷을 만들지 않는다. 빈 스냅샷을 저장하면
    /// 이전에 읽어둔 값을 지워버린다.
    func test_noHeadersYieldsNil() {
        XCTAssertNil(rateLimitSnapshot(from: bag(["content-type": "application/json"]),
                                       now: now))
    }

    /// 남은 비율만 있고 리셋 시각이 없으면 창을 만들되 resetsAt 은 비운다.
    /// 활성 조직 판단에서 strict 모드가 이 값을 걸러낸다.
    func test_remainingWithoutResetKeepsWindowButNoDeadline() {
        let s = rateLimitSnapshot(from: bag([
            "anthropic-ratelimit-unified-5h-remaining": "10",
        ]), now: now)
        XCTAssertEqual(s?.fiveHour?.usedRatio ?? -1, 0.90, accuracy: 1e-9)
        XCTAssertNil(s?.fiveHour?.resetsAt)
    }

    func test_clampsOutOfRangeRemaining() {
        let high = rateLimitSnapshot(from: bag(["anthropic-ratelimit-unified-5h-remaining": "150"]),
                                     now: now)
        XCTAssertEqual(high?.fiveHour?.usedRatio ?? -1, 0.0, accuracy: 1e-9)
        let low = rateLimitSnapshot(from: bag(["anthropic-ratelimit-unified-5h-remaining": "-5"]),
                                    now: now)
        XCTAssertEqual(low?.fiveHour?.usedRatio ?? -1, 1.0, accuracy: 1e-9)
    }

    func test_ignoresUnparseableValues() {
        XCTAssertNil(rateLimitSnapshot(from: bag([
            "anthropic-ratelimit-unified-5h-remaining": "n/a",
        ]), now: now))
    }

    /// 헤더가 준 값이 그대로 구속 여유 계산으로 이어져야 쓸모가 있다.
    func test_snapshotFeedsBindingHeadroom() {
        let s = rateLimitSnapshot(from: bag([
            "anthropic-ratelimit-unified-5h-remaining": "40",
            "anthropic-ratelimit-unified-5h-reset": "1700003600",
            "anthropic-ratelimit-unified-7d-remaining": "12",
            "anthropic-ratelimit-unified-7d-reset": "1700600000",
        ]), now: now)
        let headroom = bindingHeadroom(s, for: "claude-opus-4-5", now: now,
                                       requireKnownReset: true)
        XCTAssertEqual(headroom ?? -1, 0.12, accuracy: 1e-9, "가장 좁은 창이 구속한다")
    }
}
