import XCTest
@testable import ClflDesktop

/// Enterprise 구독에는 시간 창이 없다.
///
/// 실측으로 확인했다. `limits` 가 빈 배열이고 `five_hour` 와 `seven_day` 는
/// 전부 `null` 이다. 대신 `spend` 로 월 예산이 온다.
/// docs/design/12-enterprise-spend.md
final class SpendParsingTests: XCTestCase {
    /// 실제 응답에서 필요한 부분만 옮겼다.
    let enterprise = Data("""
    {
      "five_hour": null, "seven_day": null, "seven_day_opus": null,
      "limits": [],
      "spend": {
        "used":  {"amount_minor": 1234, "currency": "USD", "exponent": 2},
        "limit": {"amount_minor": 7500, "currency": "USD", "exponent": 2},
        "percent": 16, "severity": "normal", "enabled": true
      }
    }
    """.utf8)

    func test_readsTheBudget() throws {
        let spend = try XCTUnwrap(parseReport(enterprise).spend)
        XCTAssertEqual(spend.usedMinor, 1234)
        XCTAssertEqual(spend.limitMinor, 7500)
        XCTAssertEqual(spend.currency, "USD")
        XCTAssertEqual(spend.exponent, 2)
    }

    /// 서버는 사용률을 준다. 화면에는 잔여를 그린다. 시간 창과 같은 규칙이다.
    func test_percentIsUsedNotRemaining() throws {
        let spend = try XCTUnwrap(parseReport(enterprise).spend)
        XCTAssertEqual(spend.percentUsed, 16)
        XCTAssertEqual(spend.percentRemaining, 84)
    }

    /// 등급 경계는 시간 창과 같다. 돈이라고 다르게 볼 이유가 없다.
    func test_bandFollowsTheSameThresholds() {
        XCTAssertEqual(spend(percent: 16).band, .ample)
        XCTAssertEqual(spend(percent: 60).band, .normal)
        XCTAssertEqual(spend(percent: 90).band, .low)
        XCTAssertEqual(spend(percent: 99).band, .empty)
    }

    /// Enterprise 는 시간 창이 없다. 억지로 만들지 않는다.
    func test_enterpriseHasNoWindows() throws {
        XCTAssertTrue(parseReport(enterprise).limits.isEmpty)
    }

    /// 팀 응답에는 spend 가 없다. 없는 것을 0 으로 지어내지 않는다.
    func test_teamHasNoSpend() throws {
        let team = Data(#"{"limits":[{"kind":"session","percent":48}]}"#.utf8)
        XCTAssertNil(parseReport(team).spend)
        XCTAssertEqual(parseReport(team).limits.count, 1)
    }

    func test_missingFieldsAreNotASpend() {
        XCTAssertNil(parseReport(Data("{}".utf8)).spend)
        XCTAssertNil(parseReport(Data(#"{"spend":{"percent":0}}"#.utf8)).spend)
    }

    /// 한도가 0 이면 예산이 없는 것이다. 0 으로 나누지 않는다.
    func test_zeroLimitIsNotABudget() {
        let zero = Data("""
        {"spend":{"used":{"amount_minor":0,"currency":"USD","exponent":2},
                  "limit":{"amount_minor":0,"currency":"USD","exponent":2},"percent":0}}
        """.utf8)
        XCTAssertNil(parseReport(zero).spend)
    }

    private func spend(percent: Int) -> SpendUsage {
        SpendUsage(usedMinor: 0, limitMinor: 7500, currency: "USD", exponent: 2,
                   percentUsed: percent, severity: "normal")
    }
}

/// 금액은 응답이 준 단위로 만든다. 통화를 하드코딩하지 않는다.
final class MoneyTextTests: XCTestCase {

    func test_dollars() {
        let s = SpendUsage(usedMinor: 1234, limitMinor: 7500, currency: "USD",
                           exponent: 2, percentUsed: 16, severity: "normal")
        XCTAssertEqual(s.usedText, "$12.34")
        XCTAssertEqual(s.limitText, "$75.00")
    }

    /// 통화마다 소수 자리가 다르다. exponent 를 그대로 따른다.
    func test_currencyWithoutDecimals() {
        let s = SpendUsage(usedMinor: 5000, limitMinor: 100_000, currency: "KRW",
                           exponent: 0, percentUsed: 5, severity: "normal")
        XCTAssertTrue(s.limitText.contains("100,000"), s.limitText)
        XCTAssertFalse(s.limitText.contains("."), s.limitText)
    }

    func test_zeroUsed() {
        let s = SpendUsage(usedMinor: 0, limitMinor: 7500, currency: "USD",
                           exponent: 2, percentUsed: 0, severity: "normal")
        XCTAssertEqual(s.usedText, "$0.00")
    }
}
