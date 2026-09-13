import XCTest
@testable import ClfDesktop

/// 작업 폴더가 사라진 레코드를 지운다.
///
/// 목록에서 빼는 것은 `summaries` 가 하고 파일을 없애는 것은 여기가 한다.
/// 둘 다 있어야 앱이 되살려도 조용하다.
final class StaleSessionsTests: XCTestCase {
    private var root: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-\(UUID().uuidString)")
        store = SessionStore(dataDirectory: root, person: "p", account: "A")
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func put(_ name: String, cwd: String, cli: String = "c1") throws -> URL {
        let url = store.root.appendingPathComponent(name)
        try Data(#"{"sessionId":"s","cliSessionId":"\#(cli)","cwd":"\#(cwd)"}"#.utf8).write(to: url)
        return url
    }
    private func sweep(_ exists: @escaping (String) -> Bool) -> [String] {
        StaleSessions.sweep(stores: [store], shared: ledger, folderExists: exists)
    }
    private var ledger: SharedSessions { try! SharedSessions(directory: root) }

    func test_removesTheRecordWhenTheFolderIsGone() throws {
        let url = try put("local_x.json", cwd: "/repo/wt")
        XCTAssertEqual(sweep { _ in false }, ["c1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// 무덤이 없으면 앱의 가져오기가 다음번에 되살린다.
    func test_leavesATombstone() throws {
        try put("local_x.json", cwd: "/repo/wt")
        _ = sweep { _ in false }
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: store.root.appendingPathComponent("deleted_c1").path))
    }

    func test_keepsTheRecordWhenTheFolderIsThere() throws {
        let url = try put("local_x.json", cwd: root.path)
        XCTAssertTrue(sweep { _ in true }.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 경로를 모르는 레코드는 그냥 둔다. 짐작으로 지우면 되돌릴 수 없다.
    func test_keepsTheRecordWithoutAPath() throws {
        let url = try put("local_x.json", cwd: "")
        XCTAssertTrue(sweep { _ in false }.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 레코드가 없어졌으니 공유도 없다. 장부에 남기면 없는 공유를 계속 맞춘다.
    func test_dropsItFromTheSharedLedger() throws {
        ledger.share("c1", accounts: ["A", "B"])
        try put("local_x.json", cwd: "/repo/wt")
        _ = sweep { _ in false }
        XCTAssertNil(ledger.all()["c1"])
    }
}
