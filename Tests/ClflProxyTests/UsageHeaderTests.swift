import XCTest
import ClflCore
@testable import ClflProxy

/// 응답 헤더에서 읽어내는 사용량. Usage API 를 못 부르는 자격증명에서는
/// 이것이 유일한 관측 경로다. docs/design/02-domain-model.md 2절
///
/// 아래 이름과 의미는 실제 api.anthropic.com 응답에서 그대로 옮겼다.
/// 서버는 잔여가 아니라 **사용률(0..1)** 을 준다. 처음에는 -remaining 이라는
/// 있지도 않은 헤더를 찾고 있었고, 그래서 사용량이 영영 비어 보였다.
final class RateLimitHeaderTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func bag(_ pairs: [String: String]) -> HeaderBag {
        var b = HeaderBag()
        for (k, v) in pairs { b[k] = v }
        return b
    }

    /// 실제 응답에서 그대로 옮긴 헤더 묶음.
    let live: [String: String] = [
        "anthropic-ratelimit-unified-status": "allowed",
        "anthropic-ratelimit-unified-5h-status": "allowed",
        "anthropic-ratelimit-unified-5h-reset": "1785600000",
        "anthropic-ratelimit-unified-5h-utilization": "0.16",
        "anthropic-ratelimit-unified-7d-status": "allowed",
        "anthropic-ratelimit-unified-7d-reset": "1786050000",
        "anthropic-ratelimit-unified-7d-utilization": "0.11",
        "anthropic-ratelimit-unified-representative-claim": "five_hour",
        "anthropic-ratelimit-unified-reset": "1785600000",
    ]

    func test_readsRealResponse() {
        let s = rateLimitSnapshot(from: bag(live), now: now)
        XCTAssertEqual(s?.fiveHour?.usedRatio ?? -1, 0.16, accuracy: 1e-9)
        XCTAssertEqual(s?.sevenDayAll?.usedRatio ?? -1, 0.11, accuracy: 1e-9)
        XCTAssertEqual(s?.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_785_600_000))
        XCTAssertEqual(s?.sevenDayAll?.resetsAt, Date(timeIntervalSince1970: 1_786_050_000))
    }

    /// 잔여는 파생값이다. 0.16 사용이면 84% 남았다. 메뉴바가 이 숫자를 그린다.
    func test_remainingIsDerived() {
        let s = rateLimitSnapshot(from: bag(live), now: now)
        XCTAssertEqual(s?.fiveHour?.remaining ?? -1, 0.84, accuracy: 1e-9)
    }

    /// 서버는 사용률을 0..1 로 준다. 백분율로 읽으면 100배 틀린다.
    func test_utilizationIsARatioNotAPercentage() {
        let s = rateLimitSnapshot(from: bag([
            "anthropic-ratelimit-unified-5h-utilization": "0.5",
        ]), now: now)
        XCTAssertEqual(s?.fiveHour?.usedRatio ?? -1, 0.5, accuracy: 1e-9)
    }

    /// 헤더는 조직 전체만 말한다. 모델별 주간은 Usage API 에만 있다.
    func test_headersNeverFillModelWeekly() {
        let s = rateLimitSnapshot(from: bag(live), now: now)
        XCTAssertTrue(s?.modelWeekly.isEmpty ?? false)
        XCTAssertEqual(s?.source, .headers)
    }

    /// 관련 헤더가 하나도 없으면 스냅샷을 만들지 않는다. 빈 스냅샷을 저장하면
    /// 이전에 읽어둔 값을 지워버린다.
    func test_noHeadersYieldsNil() {
        XCTAssertNil(rateLimitSnapshot(from: bag(["content-type": "application/json"]),
                                       now: now))
    }

    /// 일시 과부하 429 에는 ratelimit 헤더가 하나도 없다. 실제로 관측했다.
    func test_transientOverloadResponseYieldsNoSnapshot() {
        XCTAssertNil(rateLimitSnapshot(from: bag(["x-should-retry": "true"]), now: now))
    }

    func test_utilizationWithoutResetKeepsWindowButNoDeadline() {
        let s = rateLimitSnapshot(from: bag([
            "anthropic-ratelimit-unified-5h-utilization": "0.9",
        ]), now: now)
        XCTAssertEqual(s?.fiveHour?.usedRatio ?? -1, 0.9, accuracy: 1e-9)
        XCTAssertNil(s?.fiveHour?.resetsAt)
    }

    func test_clampsOutOfRangeUtilization() {
        let high = rateLimitSnapshot(from: bag(["anthropic-ratelimit-unified-5h-utilization": "1.5"]),
                                     now: now)
        XCTAssertEqual(high?.fiveHour?.usedRatio ?? -1, 1.0, accuracy: 1e-9)
        let low = rateLimitSnapshot(from: bag(["anthropic-ratelimit-unified-5h-utilization": "-0.2"]),
                                    now: now)
        XCTAssertEqual(low?.fiveHour?.usedRatio ?? -1, 0.0, accuracy: 1e-9)
    }

    func test_ignoresUnparseableValues() {
        XCTAssertNil(rateLimitSnapshot(from: bag([
            "anthropic-ratelimit-unified-5h-utilization": "n/a",
        ]), now: now))
    }

    /// 헤더가 준 값이 그대로 구속 여유 계산으로 이어져야 쓸모가 있다.
    func test_snapshotFeedsBindingHeadroom() {
        let s = rateLimitSnapshot(from: bag(live), now: now)
        let headroom = bindingHeadroom(s, for: "claude-opus-4-5", now: now,
                                       requireKnownReset: true)
        XCTAssertEqual(headroom ?? -1, 0.84, accuracy: 1e-9,
                       "5시간 84% 와 주간 89% 중 좁은 쪽")
    }
}
