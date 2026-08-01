import XCTest
@testable import ClflDesktop

private func org(_ name: String, _ remaining: Int?, active: Bool = false,
                 uuid: String? = nil) -> OrgUsage {
    OrgUsage(uuid: uuid ?? name, name: name, isActive: active, plan: "team",
             limits: remaining.map { [.session: UsageLimit(percentUsed: 100 - $0,
                                                           resetsAt: nil, severity: "normal")] } ?? [:],
             error: remaining == nil ? "토큰 만료" : nil)
}

final class BarLabelTests: XCTestCase {

    /// 활성 하나만 그릴 때는 이름을 안 붙인다. 어느 조직인지는 앱이 이미 안다.
    func test_singleOrgShowsOnlyThePercent() {
        XCTAssertEqual(BarText.label(for: [org("NAVER_TEAM_40", 51, active: true)]), "51%")
    }

    /// 여럿이면 어느 것이 어느 것인지 알아야 한다.
    func test_multipleOrgsGetShortNames() {
        XCTAssertEqual(
            BarText.label(for: [org("NAVER_TEAM_40", 51, active: true), org("Naver", 88)]),
            "T40 51%  Na 88%")
    }

    /// 가장 좁은 창을 쓴다. 5시간이 널널해도 주간이 바닥이면 바닥이 사실이다.
    func test_showsTheNarrowestWindow() {
        let tight = OrgUsage(uuid: "a", name: "A", isActive: true, plan: "team", limits: [
            .session: UsageLimit(percentUsed: 10, resetsAt: nil, severity: "normal"),
            .weeklyAll: UsageLimit(percentUsed: 97, resetsAt: nil, severity: "normal"),
        ])
        XCTAssertEqual(BarText.label(for: [tight]), "3%")
    }

    /// 못 읽은 조직을 0% 로 그리면 한도가 찬 것처럼 보인다. 모르는 건 모른다고 한다.
    func test_unreadableOrgIsNotZero() {
        XCTAssertEqual(BarText.label(for: [org("Naver", nil)]), "?")
        XCTAssertEqual(BarText.label(for: [org("NAVER_TEAM_40", 51, active: true), org("Naver", nil)]),
                       "T40 51%  Na ?")
    }

    /// 전부 숨겼거나 아직 못 읽었다. 빈 막대는 앱이 죽은 것처럼 보인다.
    func test_emptyFallsBackToTheAppName() {
        XCTAssertEqual(BarText.label(for: []), "clfl")
    }
}

/// 리셋까지 남은 시간. 팝오버가 줄마다 쓴다.
final class ResetTextTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func inSeconds(_ s: TimeInterval) -> String {
        BarText.until(now.addingTimeInterval(s), from: now)
    }

    func test_hoursAndMinutes() {
        XCTAssertEqual(inSeconds(3 * 3600 + 1 * 60), "3시간 1분 뒤")
    }

    /// 시간이 0 이면 안 쓴다. "0시간 12분" 은 사람이 안 쓰는 말이다.
    func test_minutesOnly() {
        XCTAssertEqual(inSeconds(12 * 60), "12분 뒤")
    }

    /// 며칠 남았으면 분은 잡음이다.
    func test_daysDropMinutes() {
        XCTAssertEqual(inSeconds(5 * 86400 + 5 * 3600 + 30 * 60), "5일 5시간 뒤")
        XCTAssertEqual(inSeconds(2 * 86400), "2일 뒤")
    }

    func test_imminent() {
        XCTAssertEqual(inSeconds(30), "곧")
    }

    /// 지난 시각이면 리셋이 됐는데 아직 못 읽은 것이다. 음수를 그리지 않는다.
    func test_pastResetReadsAsDone() {
        XCTAssertEqual(inSeconds(-600), "지남")
    }

    /// 사용률 0 인 창은 리셋 시각이 없다. 창이 아직 안 열린 것이다.
    func test_noResetMeansTheWindowNeverOpened() {
        XCTAssertEqual(BarText.until(nil, from: now), "창 안 열림")
    }
}
