import XCTest
@testable import ClfDesktop

/// 지우기 전에 무엇이 사라지는지 먼저 말한다.
final class PurgePlanTests: XCTestCase {
    private func entry(_ name: String, _ mb: Int, running: Bool = false) -> PurgePlan.Entry {
        .init(name: name, bytes: Int64(mb) * 1024 * 1024, isRunning: running)
    }

    func test_countsOnlyWhatItWillDelete() {
        let plan = PurgePlan(entries: [entry("A", 300), entry("B", 200, running: true)])
        XCTAssertEqual(plan.deletable.map(\.name), ["A"])
        XCTAssertEqual(plan.keptRunning.map(\.name), ["B"])
        XCTAssertEqual(plan.freedBytes, 300 * 1024 * 1024)
    }

    /// 지울 것이 없으면 물어볼 것도 없다.
    func test_nothingToDelete() {
        XCTAssertTrue(PurgePlan(entries: []).isEmpty)
        XCTAssertTrue(PurgePlan(entries: [entry("A", 300, running: true)]).isEmpty)
    }

    /// 몇 개인지가 아니라 무엇인지 말한다. 이름을 봐야 판단할 수 있다.
    func test_saysWhichOnes() {
        let text = PurgePlan(entries: [entry("NAVER_TEAM_52", 300)]).summary
        XCTAssertTrue(text.contains("NAVER_TEAM_52"), text)
        XCTAssertTrue(text.contains("300"), text)
    }

    /// 남기는 것이 있으면 그것도 말한다. 안 지워졌다고 오해하면 또 누른다.
    func test_saysWhatItKeeps() {
        let plan = PurgePlan(entries: [entry("A", 300), entry("B", 200, running: true)])
        XCTAssertTrue(plan.summary.contains("B"), plan.summary)
        XCTAssertTrue(plan.summary.contains("창"), plan.summary)
    }

    func test_noKeepNoMention() {
        XCTAssertFalse(PurgePlan(entries: [entry("A", 300)]).summary.contains("창"))
    }

    /// 로그인은 남는다. 다시 띄우면 씨앗부터 새로 심는다.
    func test_explainsTheConsequence() {
        let plan = PurgePlan(entries: [entry("A", 300)])
        XCTAssertFalse(plan.consequence.isEmpty)
        XCTAssertTrue(plan.consequence.contains("대화"), plan.consequence)
    }

    func test_megabytesAreRounded() {
        XCTAssertEqual(PurgePlan.size(1024 * 1024 * 300), "300MB")
        XCTAssertEqual(PurgePlan.size(1024 * 512), "1MB")
        XCTAssertEqual(PurgePlan.size(0), "0MB")
    }
}
