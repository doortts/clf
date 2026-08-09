import XCTest
@testable import ClfDesktop

/// 어느 대화를 어느 계정들이 일부러 공유하는지 적어 둔 장부.
///
/// 디스크만 봐서는 알 수 없다. 이전하다 만 찌꺼기와 일부러 공유한 것이
/// 같은 모양이라서다. 경고를 켤지 말지가 그 구별에 달렸다.
/// docs/design/14-shared-session.md
final class SharedSessionsTests: XCTestCase {
    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func ledger() throws -> SharedSessions { try SharedSessions(directory: dir) }

    func test_sharedConversationIsListed() throws {
        let s = try ledger()
        s.share("c1", accounts: ["b", "a"], at: now)
        XCTAssertEqual(s.all()["c1"]?.accounts, ["a", "b"])
        XCTAssertEqual(s.all()["c1"]?.sharedAt, now.timeIntervalSince1970)
    }

    /// 같은 대화를 세 번째 계정에도 공유하면 합친다. 덮어쓰면 앞의 둘을 잃는다.
    func test_sharingAgainMergesAccounts() throws {
        let s = try ledger()
        s.share("c1", accounts: ["a", "b"], at: now)
        s.share("c1", accounts: ["b", "c"], at: now)
        XCTAssertEqual(s.all()["c1"]?.accounts, ["a", "b", "c"])
    }

    /// 처음 공유한 시각은 안 바뀐다. 나중 것으로 덮으면 언제부터인지를 잃는다.
    func test_sharedAtKeepsTheFirstTime() throws {
        let s = try ledger()
        s.share("c1", accounts: ["a", "b"], at: now)
        s.share("c1", accounts: ["c"], at: now.addingTimeInterval(600))
        XCTAssertEqual(s.all()["c1"]?.sharedAt, now.timeIntervalSince1970)
    }

    /// 계정이 하나뿐이면 공유가 아니다. 적지 않는다.
    func test_singleAccountIsNotShared() throws {
        let s = try ledger()
        s.share("c1", accounts: ["a"], at: now)
        XCTAssertTrue(s.all().isEmpty)
    }

    func test_forgetRemovesTheEntry() throws {
        let s = try ledger()
        s.share("c1", accounts: ["a", "b"], at: now)
        s.forget("c1")
        XCTAssertTrue(s.all().isEmpty)
    }

    // MARK: 워터마크

    /// 우리가 덮어쓴 값을 적어 둔다. 겹침 판정이 이 값을 보고 가짜 활동을 뺀다.
    func test_mirrorStampIsRecorded() throws {
        let s = try ledger()
        s.share("c1", accounts: ["a", "b"], at: now)
        s.noteMirror("c1", account: "b", activityAt: now)
        XCTAssertEqual(s.mirrorStamps()["c1"]?["b"], now)
    }

    /// 다시 덮으면 워터마크도 최신으로 간다. 옛 값이 남으면 진짜 활동을 놓친다.
    func test_mirrorStampMovesForward() throws {
        let s = try ledger()
        s.share("c1", accounts: ["a", "b"], at: now)
        s.noteMirror("c1", account: "b", activityAt: now)
        s.noteMirror("c1", account: "b", activityAt: now.addingTimeInterval(300))
        XCTAssertEqual(s.mirrorStamps()["c1"]?["b"], now.addingTimeInterval(300))
    }

    /// 공유 목록에 없는 대화의 워터마크는 안 적는다. 지운 항목이 되살아난다.
    func test_mirrorStampNeedsAnEntry() throws {
        let s = try ledger()
        s.noteMirror("c1", account: "b", activityAt: now)
        XCTAssertTrue(s.all().isEmpty)
    }

    // MARK: 레코드가 사라졌을 때

    /// 한쪽에서 대화를 지우면 그 계정을 뺀다.
    func test_dropRemovesTheAccount() throws {
        let s = try ledger()
        s.share("c1", accounts: ["a", "b", "c"], at: now)
        s.noteMirror("c1", account: "b", activityAt: now)
        s.drop(account: "b", from: "c1")
        XCTAssertEqual(s.all()["c1"]?.accounts, ["a", "c"])
        // 빠진 계정의 워터마크도 같이 지운다. 남으면 장부가 자라기만 한다
        XCTAssertNil(s.all()["c1"]?.mirrored["b"])
    }

    /// 계정이 하나만 남으면 공유가 아니다. 항목을 지운다.
    ///
    /// 목록에만 남으면 유령이다. 경고 규칙이 그 유령을 계속 본다.
    func test_lastAccountRemovesTheEntry() throws {
        let s = try ledger()
        s.share("c1", accounts: ["a", "b"], at: now)
        s.drop(account: "b", from: "c1")
        XCTAssertTrue(s.all().isEmpty)
    }

    // MARK: 파일

    /// 앱이 재시작해도 공유는 공유다.
    func test_survivesReload() throws {
        let s = try ledger()
        s.share("c1", accounts: ["a", "b"], at: now)
        s.noteMirror("c1", account: "b", activityAt: now)
        XCTAssertEqual(try ledger().all()["c1"]?.accounts, ["a", "b"])
        XCTAssertEqual(try ledger().mirrorStamps()["c1"]?["b"], now)
    }

    /// 깨진 파일은 빈 장부로 친다. 장부 하나 때문에 앱이 멎으면 안 된다.
    func test_brokenFileStartsOver() throws {
        try Data("엉터리".utf8).write(to: dir.appendingPathComponent("shared-sessions.json"))
        let s = try ledger()
        s.share("c1", accounts: ["a", "b"], at: now)
        XCTAssertEqual(s.all()["c1"]?.accounts, ["a", "b"])
    }
}
