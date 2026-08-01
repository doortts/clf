import XCTest
@testable import ClflDesktop

/// 24시간을 넘는 창에는 리셋 시각도 붙인다.
///
/// "5일 1시간 뒤" 만으로는 그게 언제인지 감이 안 온다. 하루 안쪽이면 남은
/// 시간만으로 충분하다.
final class ResetStampTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let ko = Locale(identifier: "ko_KR")
    let seoul = TimeZone(identifier: "Asia/Seoul")!

    private func stamp(_ seconds: TimeInterval) -> String {
        BarText.reset(now.addingTimeInterval(seconds), from: now, locale: ko, timeZone: seoul)
    }

    /// 하루 안쪽이면 남은 시간만. 괄호가 붙으면 잡음이다.
    func test_underADayStaysRelative() {
        XCTAssertEqual(stamp(3 * 3600 + 36 * 60), "리셋: 3시간 36분 뒤")
        XCTAssertEqual(stamp(12 * 60), "리셋: 12분 뒤")
    }

    /// 정확히 24시간은 아직 넘은 것이 아니다.
    func test_exactlyOneDayIsStillRelativeOnly() {
        XCTAssertFalse(stamp(86400).contains("("))
    }

    func test_overADayGetsTheClockTime() {
        let text = stamp(5 * 86400 + 3600)
        XCTAssertTrue(text.hasPrefix("리셋: 5일 1시간 뒤 ("), text)
        XCTAssertTrue(text.hasSuffix(")"), text)
        XCTAssertTrue(text.contains("요일"), text)
        // 오전이든 오후든 하나는 있어야 한다
        XCTAssertTrue(text.contains("오전") || text.contains("오후"), text)
    }

    /// 같은 순간을 가리키는 두 표현이다. 서로 어긋나면 안 된다.
    func test_relativePartMatchesUntil() {
        let target = now.addingTimeInterval(5 * 86400 + 3600)
        let relative = BarText.until(target, from: now)
        XCTAssertTrue(BarText.reset(target, from: now, locale: ko, timeZone: seoul)
            .hasPrefix(BarText.prefix + relative))
    }

    /// 창이 안 열렸으면 `리셋:` 도 안 붙인다. 리셋할 것이 아직 없다.
    func test_noWindowNoStamp() {
        XCTAssertEqual(BarText.reset(nil, from: now, locale: ko, timeZone: seoul), "창 안 열림")
    }

    func test_pastResetReadsAsDone() {
        XCTAssertEqual(stamp(-600), "리셋: 지남")
    }

    /// 괄호가 겹치면 안 된다. ko_KR 템플릿이 요일을 괄호로 감싸는 바람에
    /// `((금요일) 오전 5:59)` 가 나온 적이 있다.
    func test_exactShape() {
        let text = stamp(5 * 86400 + 3600)
        XCTAssertFalse(text.contains("(("), text)
        let pattern = #"^리셋: \d+일( \d+시간)? 뒤 \([가-힣]+요일 (오전|오후) \d{1,2}:\d{2}\)$"#
        XCTAssertNotNil(text.range(of: pattern, options: .regularExpression), text)
    }

    /// 시간대가 다르면 시각도 다르게 나와야 한다. 하드코딩이 아니라 계산이다.
    func test_timeZoneChangesTheClock() {
        let target = now.addingTimeInterval(5 * 86400 + 3600)
        let seoulText = BarText.reset(target, from: now, locale: ko, timeZone: seoul)
        let utcText = BarText.reset(target, from: now, locale: ko,
                                    timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertNotEqual(seoulText, utcText)
    }
}
