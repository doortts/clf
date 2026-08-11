import XCTest
@testable import ClfDesktop

/// 옮긴 대화의 장부.
///
/// 어느 계정에서 지웠고 그때 활동 시각(워터마크)이 몇이었는지 적는다.
/// 청소부가 이 장부의 대화만 보고, 되살아난 레코드를 워터마크와 비교한다.
/// docs/design/15-move-janitor.html 5절
final class MovedSessionsTests: XCTestCase {
    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func ledger() throws -> MovedSessions { try MovedSessions(directory: dir) }

    func test_movedConversationIsListed() throws {
        let m = try ledger()
        m.note("c1", from: "a", watermark: now)
        XCTAssertEqual(m.all()["c1"]?.from, "a")
        XCTAssertEqual(m.all()["c1"]?.watermark, now.timeIntervalSince1970)
        XCTAssertEqual(m.all()["c1"]?.cleaned, 0)
    }

    /// 다시 옮기면 항목을 덮는다. 새 의도가 옛 의도를 이긴다.
    /// cleaned 도 0 부터다. 새 옮김의 안전핀은 새로 세야 한다.
    func test_movingAgainReplacesTheEntry() throws {
        let m = try ledger()
        m.note("c1", from: "a", watermark: now)
        m.noteCleaned("c1")
        m.note("c1", from: "b", watermark: now.addingTimeInterval(600))
        XCTAssertEqual(m.all()["c1"]?.from, "b")
        XCTAssertEqual(m.all()["c1"]?.watermark,
                       now.addingTimeInterval(600).timeIntervalSince1970)
        XCTAssertEqual(m.all()["c1"]?.cleaned, 0)
    }

    func test_forgetRemovesTheEntry() throws {
        let m = try ledger()
        m.note("c1", from: "a", watermark: now)
        m.forget("c1")
        XCTAssertTrue(m.all().isEmpty)
    }

    /// 다시 지운 횟수를 센다. 안전핀이 이 수를 본다.
    func test_cleanedCountsUp() throws {
        let m = try ledger()
        m.note("c1", from: "a", watermark: now)
        m.noteCleaned("c1")
        m.noteCleaned("c1")
        XCTAssertEqual(m.all()["c1"]?.cleaned, 2)
    }

    /// 장부에 없는 대화의 청소는 안 센다. 지운 항목이 되살아나면 안 된다.
    func test_cleanedNeedsAnEntry() throws {
        let m = try ledger()
        m.noteCleaned("c1")
        XCTAssertTrue(m.all().isEmpty)
    }

    /// 앱이 재시작해도 의도는 남는다. 되살림은 22시간 뒤에도 왔다.
    func test_survivesReload() throws {
        try ledger().note("c1", from: "a", watermark: now)
        XCTAssertEqual(try ledger().all()["c1"]?.from, "a")
    }

    /// 깨진 파일은 빈 장부로 친다.
    func test_brokenFileStartsOver() throws {
        try Data("엉터리".utf8).write(to: dir.appendingPathComponent("moved-sessions.json"))
        let m = try ledger()
        m.note("c1", from: "a", watermark: now)
        XCTAssertEqual(m.all()["c1"]?.from, "a")
    }
}
