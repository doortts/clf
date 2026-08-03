import XCTest
@testable import ClfDesktop

/// 게이지 퍼센트의 방향. 남은 용량은 100 에서 줄고 사용률은 0 에서 는다.
/// 숫자와 채움이 함께 뒤집히고 색 등급은 잔여 기준 그대로다.
/// docs/design/gauge-direction-mockup.html
final class GaugeDirectionTests: XCTestCase {

    // MARK: 숫자

    func test_remainingShowsWhatIsLeft() {
        XCTAssertEqual(GaugeDirection.remaining.displayPercent(used: 24), 76)
        XCTAssertEqual(GaugeDirection.remaining.displayPercent(used: 0), 100)
        XCTAssertEqual(GaugeDirection.remaining.displayPercent(used: 100), 0)
    }

    func test_usedShowsWhatIsSpent() {
        XCTAssertEqual(GaugeDirection.used.displayPercent(used: 24), 24)
        XCTAssertEqual(GaugeDirection.used.displayPercent(used: 0), 0)
        XCTAssertEqual(GaugeDirection.used.displayPercent(used: 100), 100)
    }

    // MARK: 눈금

    /// 남은 용량은 올림이다. 1% 라도 남았으면 한 칸을 켠다.
    func test_remainingStepsRoundUp() {
        XCTAssertEqual(GaugeDirection.remaining.litSteps(used: 99, total: 20), 1)
        XCTAssertEqual(GaugeDirection.remaining.litSteps(used: 13, total: 20), 18)
        XCTAssertEqual(GaugeDirection.remaining.litSteps(used: 0, total: 20), 20)
        XCTAssertEqual(GaugeDirection.remaining.litSteps(used: 100, total: 20), 0)
    }

    /// 사용률은 내림이다. 1% 라도 남았으면 빈 칸 하나를 남긴다.
    /// 96% 를 올림해서 스무 칸을 다 채우면 4% 남은 창이 소진으로 보인다.
    func test_usedStepsRoundDown() {
        XCTAssertEqual(GaugeDirection.used.litSteps(used: 99, total: 20), 19)
        XCTAssertEqual(GaugeDirection.used.litSteps(used: 13, total: 20), 2)
        XCTAssertEqual(GaugeDirection.used.litSteps(used: 0, total: 20), 0)
        XCTAssertEqual(GaugeDirection.used.litSteps(used: 100, total: 20), 20)
    }

    /// 두 방식은 보수 관계다. 같은 값이면 어느 쪽으로 봐도 켠 칸과 빈 칸이 맞물린다.
    func test_stepsAreComplementary() {
        for used in 0...100 {
            let sum = GaugeDirection.remaining.litSteps(used: used, total: 20)
                + GaugeDirection.used.litSteps(used: used, total: 20)
            XCTAssertEqual(sum, 20, "사용률 \(used)")
        }
    }

    // MARK: 설정

    /// 사용률이 기본값이다. 게이지가 차오르는 방향과 숫자가 같이 커진다.
    func test_defaultsToUsed() {
        XCTAssertEqual(DesktopPreferences().gaugeDirection, .used)
    }

    /// 필드가 없는 파일도 기본값으로 읽힌다.
    func test_sparseFileDecodesToUsed() throws {
        let sparse = Data(#"{"version":1}"#.utf8)
        let prefs = try JSONDecoder().decode(DesktopPreferences.self, from: sparse)
        XCTAssertEqual(prefs.gaugeDirection, .used)
    }

    /// 골라 둔 값은 기본값이 바뀌어도 그대로 남는다.
    func test_choiceSurvivesRoundTrip() throws {
        for choice in GaugeDirection.allCases {
            var prefs = DesktopPreferences()
            prefs.gaugeDirection = choice
            let data = try JSONEncoder().encode(prefs)
            XCTAssertEqual(
                try JSONDecoder().decode(DesktopPreferences.self, from: data).gaugeDirection,
                choice)
        }
    }

    // MARK: 글자 예비 표기

    /// 그림을 못 그릴 때 쓰는 글자 막대도 방향을 따른다.
    func test_barTextFollowsStyle() {
        let org = OrgUsage(uuid: "a", name: "A", isActive: true, plan: "team", limits: [
            .session: UsageLimit(percentUsed: 24, resetsAt: nil, severity: "normal"),
        ])
        XCTAssertEqual(BarText.label(for: [org], direction: .remaining), "76%")
        XCTAssertEqual(BarText.label(for: [org], direction: .used), "24%")
    }
}
