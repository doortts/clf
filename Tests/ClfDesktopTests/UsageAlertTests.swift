import XCTest
@testable import ClfDesktop

/// 알림 문구와 판단. docs/design/notify-mockup.html
final class UsageAlertTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let zone = TimeZone(identifier: "Asia/Seoul")!

    private func limit(_ used: Int, _ resetsIn: TimeInterval?) -> UsageLimit {
        UsageLimit(percentUsed: used,
                   resetsAt: resetsIn.map { now.addingTimeInterval($0) },
                   severity: "")
    }

    private func org(_ limits: [LimitKind: UsageLimit],
                     name: String = "T52", uuid: String = "u1") -> OrgUsage {
        OrgUsage(uuid: uuid, name: name, isActive: true, plan: "team", limits: limits)
    }

    private func build(_ org: OrgUsage, others: [OrgUsage] = []) -> [UsageAlert] {
        UsageAlerts.build(for: org, others: others, now: now, timeZone: zone)
    }

    // MARK: 언제 보내나

    /// 여유로운 계정은 아무 알림도 없다.
    func test_healthyOrgIsQuiet() {
        XCTAssertTrue(build(org([.session: limit(20, 3600)])).isEmpty)
    }

    /// 잔여 5% 미만이면 예고한다. 5% 는 아직 아니다.
    func test_warnsBelowFivePercentRemaining() {
        XCTAssertEqual(build(org([.session: limit(96, 8040)])).count, 1)
        XCTAssertTrue(build(org([.session: limit(95, 8040)])).isEmpty)
    }

    /// 값을 못 읽었거나 낡은 값이면 알리지 않는다. 0% 로 읽고 소진이라
    /// 말하는 것이 가장 나쁜 거짓이다.
    func test_staleOrUnreadableIsQuiet() {
        let stale = OrgUsage(uuid: "u1", name: "T52", isActive: true, plan: "team",
                             limits: [.session: limit(100, 3600)], error: "못 읽음", isStale: true)
        XCTAssertTrue(build(stale).isEmpty)

        let empty = OrgUsage(uuid: "u1", name: "T52", isActive: true, plan: nil, limits: [:])
        XCTAssertTrue(build(empty).isEmpty)
    }

    // MARK: 문구

    /// 예고 문구. 하루 안쪽이면 남은 시간만 적는다.
    func test_warningCopy() {
        let alerts = build(org([.session: limit(96, 2 * 3600 + 14 * 60)]))
        XCTAssertEqual(alerts.first?.title, "T52 5시간 한도 4% 남음")
        XCTAssertEqual(alerts.first?.body, "리셋: 2시간 14분 뒤")
        XCTAssertEqual(alerts.first?.level, .warning)
    }

    /// 하루를 넘으면 요일과 시각을 괄호로 붙인다.
    func test_warningCopyOverADayAddsTheClock() {
        let alerts = build(org([.weeklyAll: limit(97, 3 * 86_400 + 6 * 3600)]))
        XCTAssertEqual(alerts.first?.title, "T52 주간 한도 3% 남음")
        XCTAssertTrue(alerts.first?.body.hasPrefix("리셋: 3일 6시간 뒤 (") ?? false,
                      alerts.first?.body ?? "")
    }

    /// 5시간만 소진이면 주간 잔여를 덧붙인다. 기다리면 이어서 쓸 수 있다는 뜻이다.
    func test_sessionExhaustedMentionsWeeklyLeft() {
        let alerts = build(org([.session: limit(100, 2 * 3600 + 14 * 60),
                                .weeklyAll: limit(53, 3 * 86_400)]))
        let exhausted = alerts.first { $0.level == .exhausted }
        XCTAssertEqual(exhausted?.title, "T52 5시간 한도 소진")
        XCTAssertEqual(exhausted?.body, "리셋: 2시간 14분 뒤. 주간은 47% 남았습니다.")
    }

    /// 두 창이 소진이면 늦게 풀리는 쪽만 말한다. 5시간 리셋은 알려줄 값이 없다.
    func test_twoExhaustedWindowsReportTheLaterOne() {
        let alerts = build(org([.session: limit(100, 2 * 3600),
                                .weeklyAll: limit(100, 3 * 86_400 + 6 * 3600)]))
        let exhausted = alerts.filter { $0.level == .exhausted }
        XCTAssertEqual(exhausted.count, 1)
        XCTAssertEqual(exhausted.first?.title, "T52 주간 한도 소진")
        XCTAssertTrue(exhausted.first?.body.hasPrefix("리셋: 3일 6시간 뒤 (") ?? false)
    }

    /// Fable 창만 소진이면 다른 모델은 쓸 수 있다고 못박는다.
    func test_fableOnlyExhaustedSaysOtherModelsWork() {
        let alerts = build(org([.session: limit(10, 3600),
                                .weeklyAll: limit(20, 86_400),
                                .weeklyScoped: limit(100, 41 * 3600)]))
        let exhausted = alerts.first { $0.level == .exhausted }
        XCTAssertEqual(exhausted?.title, "T52 주간 Fable 소진")
        XCTAssertTrue(exhausted?.body.hasSuffix("다른 모델은 쓸 수 있습니다.") ?? false,
                      exhausted?.body ?? "")
    }

    /// 세 창이 다 소진이면 제목이 바뀌고 여유 있는 다른 계정을 알려준다.
    func test_allExhaustedNamesASpareAccount() {
        let dead = org([.session: limit(100, 3600),
                        .weeklyAll: limit(100, 2 * 86_400),
                        .weeklyScoped: limit(100, 2 * 86_400)])
        let spare = org([.session: limit(38, 3600)], name: "T40", uuid: "u2")
        let alerts = build(dead, others: [spare])
        let exhausted = alerts.first { $0.level == .exhausted }
        XCTAssertEqual(exhausted?.title, "T52 한도 전부 소진")
        XCTAssertTrue(exhausted?.body.hasSuffix("T40 은 62% 남았습니다.") ?? false,
                      exhausted?.body ?? "")
    }

    /// 다른 계정도 바닥이면 권할 곳이 없다. 없는 여유를 지어내지 않는다.
    func test_allExhaustedWithNoSpareStaysShort() {
        let dead = org([.session: limit(100, 3600),
                        .weeklyAll: limit(100, 2 * 86_400),
                        .weeklyScoped: limit(100, 2 * 86_400)])
        let alsoDead = org([.session: limit(99, 3600)], name: "T40", uuid: "u2")
        let alerts = build(dead, others: [alsoDead])
        let exhausted = alerts.first { $0.level == .exhausted }
        XCTAssertFalse(exhausted?.body.contains("남았습니다") ?? true, exhausted?.body ?? "")
    }

    /// 리셋 시각이 없으면 창 길이를 지어내지 않는다.
    func test_unknownResetSaysSo() {
        let alerts = build(org([.session: limit(100, nil)]))
        XCTAssertEqual(alerts.first?.body, "리셋 시각을 아직 모릅니다.")
    }

    /// 월 예산은 리셋 시각이 응답에 없다. 그 사실을 말한다.
    func test_budgetExhausted() {
        let spend = SpendUsage(usedMinor: 7500, limitMinor: 7500, currency: "USD",
                               exponent: 2, percentUsed: 100, severity: "critical")
        let org = OrgUsage(uuid: "u3", name: "Naver", isActive: false, plan: "enterprise",
                           limits: [:], spend: spend)
        let alerts = build(org)
        XCTAssertEqual(alerts.first?.title, "Naver 월 예산 소진")
        XCTAssertEqual(alerts.first?.body, "$75.00 를 다 썼습니다. 리셋 시각은 서버가 주지 않습니다.")
    }

    // MARK: 열쇠

    /// 소진과 예고는 뜻이 다른 두 알림이라 열쇠도 갈린다.
    func test_keySeparatesLevels() {
        let alerts = build(org([.session: limit(100, 3600), .weeklyAll: limit(97, 86_400)]))
        XCTAssertEqual(Set(alerts.map(\.key)).count, 2)
        XCTAssertTrue(alerts.contains { $0.key.hasSuffix("|exhausted|1700003600") })
    }

    /// 창이 새로 열리면 리셋 시각이 달라지므로 다시 보낼 수 있다.
    func test_keyChangesWithTheResetTime() {
        let first = build(org([.session: limit(100, 3600)])).first?.key
        let later = build(org([.session: limit(100, 5 * 3600)])).first?.key
        XCTAssertNotEqual(first, later)
    }

    /// 같은 창, 같은 등급, 같은 리셋 시각이면 열쇠가 같다. 이것으로 중복을 막는다.
    func test_keyIsStableForTheSameWindow() {
        let a = build(org([.session: limit(100, 3600)])).first?.key
        let b = build(org([.session: limit(100, 3600)])).first?.key
        XCTAssertEqual(a, b)
    }
}
