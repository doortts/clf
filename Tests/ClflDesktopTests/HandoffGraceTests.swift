import XCTest
@testable import ClflDesktop

/// 넘긴 직후의 겹침은 경고하지 않는다.
///
/// 넘기면 옛 창이 세션을 여전히 쥐고 있어 레코드가 되살아나고, 그 순간
/// 두 계정이 같은 대화를 가리킨다. 사용자가 방금 스스로 한 일이라 그때
/// 경고하면 혼란만 준다.
final class HandoffGraceTests: XCTestCase {
    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func grace() throws -> HandoffGrace { try HandoffGrace(directory: dir) }

    func test_notedConversationIsMuted() throws {
        let g = try grace()
        g.note("c1", at: now)
        XCTAssertEqual(g.muted(now: now), ["c1"])
    }

    /// 15분이면 옛 창을 재시작하거나 세션이 정리된다. 그 뒤는 진짜 겹침이다.
    func test_muteExpiresAfterTheWindow() throws {
        let g = try grace()
        g.note("c1", at: now)
        XCTAssertEqual(g.muted(now: now.addingTimeInterval(HandoffGrace.window + 1)), [])
    }

    func test_unknownConversationIsNotMuted() throws {
        XCTAssertEqual(try grace().muted(now: now), [])
    }

    /// 앱이 재시작해도 참을 것은 계속 참아야 한다. 그래서 파일이다.
    func test_survivesReload() throws {
        try grace().note("c1", at: now)
        XCTAssertEqual(try grace().muted(now: now), ["c1"])
    }

    /// 지난 항목은 적을 때 지운다. 파일이 자라기만 하면 안 된다.
    func test_prunesExpiredEntriesOnWrite() throws {
        let g = try grace()
        g.note("old", at: now.addingTimeInterval(-HandoffGrace.window - 60))
        g.note("new", at: now)
        XCTAssertEqual(try grace().muted(now: now), ["new"])
    }

    /// 깨진 파일은 빈 것으로 친다. 장부 하나 때문에 경고가 멎으면 안 된다.
    func test_brokenFileStartsOver() throws {
        try Data("엉터리".utf8).write(to: dir.appendingPathComponent("handoff-grace.json"))
        let g = try grace()
        g.note("c1", at: now)
        XCTAssertEqual(g.muted(now: now), ["c1"])
    }
}
