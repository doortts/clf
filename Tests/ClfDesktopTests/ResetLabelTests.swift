import XCTest
@testable import ClfDesktop

/// 막대 라벨 자리의 남은 시간 표기.
///
/// 자리가 세 글자뿐이라 단위 하나만 쓰고 내림한다. 올림하면 `1h` 가 실제로는
/// 1분 남은 창일 수 있다. docs/design/bar-reset-remaining-mockup.html
final class ShortUntilTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func short(_ seconds: Double) -> String {
        BarText.shortUntil(now.addingTimeInterval(seconds), from: now)
    }

    func test_daysWhilePastOneDay() {
        XCTAssertEqual(short(6 * 86400 + 23 * 3600), "6d")
        XCTAssertEqual(short(86400), "1d")
    }

    /// 하루에서 1초 빠지면 아직 시간 단위다. `0d` 는 아무 말도 안 한다.
    func test_hoursUnderADay() {
        XCTAssertEqual(short(86400 - 1), "23h")
        XCTAssertEqual(short(4 * 3600 + 6 * 60), "4h")
        XCTAssertEqual(short(3600), "1h")
    }

    func test_minutesUnderAnHour() {
        XCTAssertEqual(short(3600 - 1), "59m")
        XCTAssertEqual(short(9 * 60 + 50), "9m")
        XCTAssertEqual(short(60), "1m")
    }

    /// 1분 미만은 `0m` 이다. 곧 리셋이라는 뜻이 그대로 읽힌다.
    func test_underAMinute() {
        XCTAssertEqual(short(30), "0m")
    }

    /// 시계가 어긋나 지난 시각이 와도 음수를 그리지 않는다.
    func test_pastIsNotNegative() {
        XCTAssertEqual(short(-500), "0m")
    }

    /// 창을 아직 안 썼으면 리셋 시각이 없다. 0 으로 채우면 곧 리셋이라는 거짓이다.
    func test_noResetTimeIsADash() {
        XCTAssertEqual(BarText.shortUntil(nil, from: now), "-")
    }

    /// 사용률 0 인 창은 서버가 리셋 시각을 안 준다. 그때는 창 길이를 적는다.
    ///
    /// 아직 안 열린 창의 남은 시간은 창 길이 전체다. `-` 로 비우면 옆 숫자만
    /// 남아 무슨 창인지도 사라진다.
    func test_windowLengthFillsInForAnUnopenedWindow() {
        XCTAssertEqual(BarText.shortUntil(nil, window: LimitKind.session.window, from: now), "5h")
        XCTAssertEqual(BarText.shortUntil(nil, window: LimitKind.weeklyAll.window, from: now), "7d")
    }

    /// 리셋 시각이 있으면 창 길이는 안 본다.
    func test_realResetTimeWins() {
        XCTAssertEqual(
            BarText.shortUntil(now.addingTimeInterval(2 * 3600),
                               window: LimitKind.session.window, from: now), "2h")
    }
}

/// 라벨 설정.
final class ResetLabelPrefsTests: XCTestCase {
    /// 남은 시간이 기본값이다. 창 종류는 순서로도 알 수 있다.
    func test_defaultsToRemaining() {
        XCTAssertEqual(DesktopPreferences().resetLabel, .remaining)
    }

    func test_sparseFileDecodesToRemaining() throws {
        let sparse = Data(#"{"version":1}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(DesktopPreferences.self, from: sparse).resetLabel,
                       .remaining)
    }

    func test_choiceSurvivesRoundTrip() throws {
        for choice in ResetLabel.allCases {
            var prefs = DesktopPreferences()
            prefs.resetLabel = choice
            let data = try JSONEncoder().encode(prefs)
            XCTAssertEqual(
                try JSONDecoder().decode(DesktopPreferences.self, from: data).resetLabel, choice)
        }
    }

    /// 표시 안 함만 라벨 열을 뺀다.
    func test_onlyNoneHidesTheTag() {
        XCTAssertTrue(ResetLabel.period.showsTag)
        XCTAssertTrue(ResetLabel.remaining.showsTag)
        XCTAssertFalse(ResetLabel.none.showsTag)
    }
}
