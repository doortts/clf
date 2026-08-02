import XCTest
@testable import ClflDesktop

/// 게이지 숫자 색. 바깥을 어둡게 깔면서 구간마다 읽히는 색이 갈렸다.
final class GaugeInkTests: XCTestCase {
    func test_grayAndRedTakeWhite() {
        XCTAssertTrue(UsageBand.normal.prefersLightInk)
        XCTAssertTrue(UsageBand.empty.prefersLightInk)
    }

    /// 어두워진 노랑은 아직 밝다. 흰 글자면 대비가 2.5 로 떨어진다
    func test_yellowKeepsBlack() {
        XCTAssertFalse(UsageBand.low.prefersLightInk)
    }

    func test_greenKeepsBlack() {
        XCTAssertFalse(UsageBand.ample.prefersLightInk)
    }
}
