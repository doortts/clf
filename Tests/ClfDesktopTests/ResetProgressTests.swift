import XCTest
@testable import ClfDesktop

/// 리셋 줄에 붙는 창 진행률.
///
/// "10분 뒤" 만으로는 그 창이 얼마나 지났는지 모른다. 5시간 창의 10분과
/// 주간 창의 10분은 뜻이 다르다. docs/design/reset-progress-mockup.html
final class ResetProgressTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let ko = Locale(identifier: "ko_KR")
    let seoul = TimeZone(identifier: "Asia/Seoul")!

    private func line(_ left: TimeInterval, _ window: TimeInterval,
                      _ direction: GaugeDirection = .used) -> String {
        BarText.reset(now.addingTimeInterval(left), window: window, direction: direction,
                      from: now, locale: ko, timeZone: seoul)
    }

    /// 5시간 창이 10분 남았으면 거의 다 지난 것이다.
    func test_showsHowFarTheWindowHasRun() {
        XCTAssertEqual(line(10 * 60, 5 * 3600), "리셋: 97%, 10분 뒤")
    }

    /// 하루를 넘으면 리셋 시각도 그대로 뒤에 붙는다.
    func test_keepsTheStamp() {
        let text = line(4 * 86_400 + 6 * 3600, 7 * 86_400)
        XCTAssertTrue(text.hasPrefix("리셋: 39%, 4일 6시간 뒤 ("), text)
    }

    /// 창 길이를 안 주면 예전 그대로. 퍼센트를 못 내는 자리가 있다.
    func test_withoutAWindowNothingChanges() {
        XCTAssertEqual(BarText.reset(now.addingTimeInterval(600), from: now,
                                     locale: ko, timeZone: seoul), "리셋: 10분 뒤")
    }

    /// 아직 안 열린 창은 리셋 시각이 없다. 퍼센트도 없다.
    func test_unopenedWindowHasNoPercent() {
        XCTAssertEqual(BarText.reset(nil, window: 5 * 3600, from: now,
                                     locale: ko, timeZone: seoul), "창 안 열림")
    }

    /// 리셋 시각이 지났으면 다 지난 것이다.
    func test_pastReadsAsFull() {
        XCTAssertEqual(line(-60, 5 * 3600), "리셋: 100%, 지남")
    }

    /// 시계가 어긋나 창 길이보다 더 남을 수 있다. 음수를 보여주면 안 된다.
    func test_clampsWhenMoreTimeIsLeftThanTheWindow() {
        XCTAssertTrue(line(6 * 3600, 5 * 3600).hasPrefix("리셋: 0%,"))
    }

    /// 게이지가 남은 쪽을 세면 리셋도 남은 쪽을 센다. 한 창을 두고 두 숫자가
    /// 반대로 움직이면 화면이 어긋나 보인다.
    func test_followsTheGaugeDirection() {
        XCTAssertEqual(line(4 * 3600 + 46 * 60, 5 * 3600, .remaining), "리셋: 95%, 4시간 46분 뒤")
        XCTAssertEqual(line(4 * 3600 + 46 * 60, 5 * 3600, .used), "리셋: 5%, 4시간 46분 뒤")
    }

    /// 남은 쪽을 셀 때는 0 이 리셋 시점이다.
    func test_remainingCountsDownToZero() {
        XCTAssertEqual(line(-60, 5 * 3600, .remaining), "리셋: 0%, 지남")
    }

    /// 창 길이는 종류가 정한다. 서버는 안 준다.
    func test_windowPerKind() {
        XCTAssertEqual(LimitKind.session.window, 5 * 3600)
        XCTAssertEqual(LimitKind.weeklyAll.window, 7 * 86_400)
        XCTAssertEqual(LimitKind.weeklyScoped.window, 7 * 86_400)
    }
}
