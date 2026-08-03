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

    /// 지금까지의 방식이 기본값이다. 설정을 안 만진 사람의 화면이 바뀌면 안 된다.
    func test_defaultsToRemaining() {
        XCTAssertEqual(DesktopPreferences().gaugeDirection, .remaining)
    }

    /// 필드가 없는 옛 파일도 잔여 방식으로 읽힌다.
    func test_sparseFileDecodesToRemaining() throws {
        let sparse = Data(#"{"version":1}"#.utf8)
        let prefs = try JSONDecoder().decode(DesktopPreferences.self, from: sparse)
        XCTAssertEqual(prefs.gaugeDirection, .remaining)
    }

    func test_usedStyleSurvivesRoundTrip() throws {
        var prefs = DesktopPreferences()
        prefs.gaugeDirection = .used
        let data = try JSONEncoder().encode(prefs)
        XCTAssertEqual(try JSONDecoder().decode(DesktopPreferences.self, from: data).gaugeDirection,
                       .used)
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
