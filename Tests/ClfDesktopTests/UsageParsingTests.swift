import XCTest
@testable import ClfDesktop

/// Usage API 응답을 읽는다. 아래 JSON 은 실제 응답에서 그대로 옮겼다.
/// docs/design/10-desktop-usage.md 1절
final class UsageParsingTests: XCTestCase {

    /// 실제 응답. 필드 이름과 모양을 손대지 않았다.
    let live = Data("""
    {
      "five_hour": {"utilization": 48.0, "resets_at": "2026-08-01T16:00:00.371815+00:00"},
      "seven_day": {"utilization": 15.0, "resets_at": "2026-08-06T21:00:00.371831+00:00"},
      "seven_day_opus": null,
      "limits": [
        {"kind": "session", "group": "session", "percent": 48,
         "severity": "normal", "resets_at": "2026-08-01T16:00:00.371815+00:00",
         "scope": null, "is_active": true},
        {"kind": "weekly_all", "group": "weekly", "percent": 15,
         "severity": "normal", "resets_at": "2026-08-06T21:00:00.371831+00:00",
         "scope": null, "is_active": false},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 1,
         "severity": "normal", "resets_at": "2026-08-06T20:59:59.372078+00:00",
         "scope": null, "is_active": false}
      ]
    }
    """.utf8)

    func test_readsThreeLimits() throws {
        let limits = try parseUsage(live)
        XCTAssertEqual(limits[.session]?.percentUsed, 48)
        XCTAssertEqual(limits[.weeklyAll]?.percentUsed, 15)
        XCTAssertEqual(limits[.weeklyScoped]?.percentUsed, 1)
    }

    /// 서버는 사용률을 준다. 화면에는 잔여를 그린다.
    func test_remainingIsDerived() throws {
        let limits = try parseUsage(live)
        XCTAssertEqual(limits[.session]?.percentRemaining, 52)
        XCTAssertEqual(limits[.weeklyScoped]?.percentRemaining, 99)
    }

    /// resets_at 에 마이크로초가 붙어 온다. 기본 ISO8601 파서는 이걸 못 읽는다.
    func test_parsesTimestampWithFractionalSeconds() throws {
        let limits = try parseUsage(live)
        let at = try XCTUnwrap(limits[.session]?.resetsAt)
        XCTAssertEqual(at.timeIntervalSince1970, 1_785_600_000.371815, accuracy: 0.001,
                       "마이크로초까지 살아야 한다")
    }

    func test_carriesSeverityFromServer() throws {
        XCTAssertEqual(try parseUsage(live)[.session]?.severity, "normal")
    }

    /// 사용률 0 인 창은 리셋 시각이 없다. 창이 아직 안 열린 것이다.
    /// 없는 것을 0 이나 현재 시각으로 채우면 UI 가 거짓말한다.
    func test_missingResetStaysNil() throws {
        let idle = Data("""
        {"limits":[{"kind":"session","percent":0,"severity":"normal","resets_at":null}]}
        """.utf8)
        let limits = try parseUsage(idle)
        XCTAssertEqual(limits[.session]?.percentUsed, 0)
        XCTAssertNil(limits[.session]?.resetsAt)
    }

    /// 서버가 새 종류를 추가해도 우리가 죽으면 안 된다.
    func test_ignoresUnknownKinds() throws {
        let extra = Data("""
        {"limits":[{"kind":"session","percent":5,"severity":"normal","resets_at":null},
                   {"kind":"seven_day_omelette","percent":9,"severity":"normal","resets_at":null}]}
        """.utf8)
        let limits = try parseUsage(extra)
        XCTAssertEqual(limits.count, 1)
        XCTAssertEqual(limits[.session]?.percentUsed, 5)
    }

    func test_emptyLimitsYieldsEmpty() throws {
        XCTAssertTrue(try parseUsage(Data(#"{"limits":[]}"#.utf8)).isEmpty)
        XCTAssertTrue(try parseUsage(Data("{}".utf8)).isEmpty)
    }

    func test_malformedThrows() {
        XCTAssertThrowsError(try parseUsage(Data("not json".utf8)))
    }

    // MARK: 밴드

    /// 메뉴바 색을 정하는 경계. 잔여 기준이다.
    func test_bandBoundaries() {
        XCTAssertEqual(UsageLimit(percentUsed: 96, resetsAt: nil, severity: "").band, .empty)
        XCTAssertEqual(UsageLimit(percentUsed: 95, resetsAt: nil, severity: "").band, .low)
        XCTAssertEqual(UsageLimit(percentUsed: 86, resetsAt: nil, severity: "").band, .low)
        XCTAssertEqual(UsageLimit(percentUsed: 85, resetsAt: nil, severity: "").band, .normal)
        XCTAssertEqual(UsageLimit(percentUsed: 51, resetsAt: nil, severity: "").band, .normal)
        XCTAssertEqual(UsageLimit(percentUsed: 50, resetsAt: nil, severity: "").band, .ample)
    }
}
