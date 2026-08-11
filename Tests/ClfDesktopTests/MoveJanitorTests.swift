import XCTest
@testable import ClfDesktop

/// 청소부 판정. 파일은 안 건드린다.
///
/// 순서와 방향이 전부다. 헷갈리면 안 지운다. 틀려서 안 지우면 겹침 표시가
/// 남을 뿐이고, 틀려서 지우면 사용자 상태를 잃는다.
/// docs/design/15-move-janitor.html 7절
final class MoveJanitorJudgeTests: XCTestCase {
    private let mark = Date(timeIntervalSince1970: 1_700_000_000)

    private func judge(shared: Bool = false,
                       otherSideHasRecord: Bool = true,
                       windowUp: Bool = false,
                       resurrected: MoveJanitor.Resurrected? = nil,
                       cleaned: Int = 0) -> MoveJanitor.Verdict {
        MoveJanitor.judge(shared: shared, otherSideHasRecord: otherSideHasRecord,
                          windowUp: windowUp, resurrected: resurrected,
                          watermark: mark, cleaned: cleaned)
    }

    /// 옛 시각 그대로 되살아난 것이 시체다. 지운다.
    func test_staleResurrectionIsCleaned() {
        XCTAssertEqual(judge(resurrected: .init(activityAt: mark.addingTimeInterval(-60))),
                       .clean)
    }

    /// **같은 시각도 시체다.** 실측한 되살림 셋 다 옛 act 그대로였다.
    func test_equalActivityIsCleaned() {
        XCTAssertEqual(judge(resurrected: .init(activityAt: mark)), .clean)
    }

    /// 더 최신이면 사용자가 진짜 이어간 것이다. 물러나고 항목을 뺀다.
    /// 백그라운드 작업 알림도 활동을 올리는데, 그 작업은 공유 트랜스크립트에
    /// 실제로 쓰는 중이라 물러나는 것이 맞다.
    func test_newerActivityBacksOff() {
        XCTAssertEqual(judge(resurrected: .init(activityAt: mark.addingTimeInterval(1))),
                       .dropEntry)
    }

    /// 시각을 모르는 레코드는 판정할 수 없다. 지우지 않고 물러난다.
    /// 헷갈리면 안 지운다.
    func test_unknownActivityBacksOff() {
        XCTAssertEqual(judge(resurrected: .init(activityAt: nil)), .dropEntry)
    }

    /// 되살아난 것이 없으면 정상이다. 항목은 남긴다. 되살림은 22시간
    /// 뒤에도 왔다.
    func test_noResurrectionLeavesTheEntry() {
        XCTAssertEqual(judge(resurrected: nil), .leaveAlone)
    }

    /// 공유해 둔 대화는 청소부의 일이 아니다. 공유 사본을 시체로 오판해
    /// 지우면 데이터 손실이다. 항목만 뺀다.
    func test_sharedConversationIsNotOurs() {
        XCTAssertEqual(judge(shared: true, resurrected: .init(activityAt: mark)), .dropEntry)
    }

    /// 어느 계정에도 레코드가 없으면 옮김 자체가 무효다. 항목만 뺀다.
    func test_vanishedMoveDropsTheEntry() {
        XCTAssertEqual(judge(otherSideHasRecord: false,
                             resurrected: .init(activityAt: mark)), .dropEntry)
    }

    /// **창이 떠 있으면 아무것도 안 한다.** 디스크를 지워도 화면의 줄은 안
    /// 사라지고 앱의 쓰기와 얽혀 결과를 예측할 수 없다.
    func test_openWindowSkipsThisRound() {
        XCTAssertEqual(judge(windowUp: true, resurrected: .init(activityAt: mark)),
                       .skipWindowUp)
    }

    /// 안전핀. 3번 넘게 되살아나면 수동 복원을 먹고 있다는 뜻일 수 있다.
    /// 포기하고 항목을 뺀다.
    func test_giveUpAfterThreeCleanings() {
        XCTAssertEqual(judge(resurrected: .init(activityAt: mark), cleaned: 3), .dropEntry)
        XCTAssertEqual(judge(resurrected: .init(activityAt: mark), cleaned: 2), .clean)
    }

    /// 문 순서. 공유가 무효보다, 무효가 창보다 앞이다. 앞의 둘은 장부
    /// 정리라 창과 무관하게 안전하다.
    func test_gateOrder() {
        XCTAssertEqual(judge(shared: true, otherSideHasRecord: false, windowUp: true),
                       .dropEntry)
        XCTAssertEqual(judge(otherSideHasRecord: false, windowUp: true), .dropEntry)
    }
}

/// 청소부가 실제로 디스크를 쓸어내는 쪽.
final class MoveJanitorSweepTests: XCTestCase {
    private var root: URL!
    private var ledger: MovedSessions!
    private let mark = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("janitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ledger = try MovedSessions(directory: root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func store(_ account: String, dir: String = "primary") -> SessionStore {
        SessionStore(dataDirectory: root.appendingPathComponent(dir), person: "p",
                     account: account)
    }

    @discardableResult
    private func put(_ store: SessionStore, cli: String = "c1", at: Date?,
                     name: String = "local_z.json") throws -> URL {
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let stamp = at.map { "\($0.timeIntervalSince1970 * 1000)" } ?? "null"
        let url = store.root.appendingPathComponent(name)
        try Data(#"{"sessionId":"\#(name.dropLast(5))","cliSessionId":"\#(cli)","lastActivityAt":\#(stamp)}"#
            .utf8).write(to: url)
        return url
    }

    private func sweep(windowsUp: Set<String> = [], sharedIDs: Set<String> = [],
                       stores: [String: [SessionStore]],
                       lastSeen: [String: Date] = [:]) -> [String: Date] {
        MoveJanitor.sweep(ledger: ledger, sharedIDs: sharedIDs, stores: stores,
                          windowsUp: windowsUp, lastSeen: lastSeen)
    }

    /// 시체는 자리마다 지우고 무덤을 세운다. 항목은 남고 안전핀이 오른다.
    func test_cleansTheZombieEverywhere() throws {
        let a = store("a"), altA = store("a", dir: "alt"), b = store("b")
        let z1 = try put(a, at: mark)
        let z2 = try put(altA, at: mark)
        try put(b, at: mark, name: "local_b.json")
        ledger.note("c1", from: "a", watermark: mark)

        sweep(stores: ["a": [a, altA], "b": [b]])

        XCTAssertFalse(FileManager.default.fileExists(atPath: z1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: z2.path))
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: a.root.appendingPathComponent("deleted_c1").path))
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: a.root.appendingPathComponent("deleted_z").path))
        XCTAssertEqual(ledger.all()["c1"]?.cleaned, 1)
    }

    /// 더 최신 활동이면 물러난다. 파일은 남고 항목이 빠진다.
    func test_realWorkSurvives() throws {
        let a = store("a"), b = store("b")
        let z = try put(a, at: mark.addingTimeInterval(60))
        try put(b, at: mark, name: "local_b.json")
        ledger.note("c1", from: "a", watermark: mark)

        sweep(stores: ["a": [a], "b": [b]])

        XCTAssertTrue(FileManager.default.fileExists(atPath: z.path))
        XCTAssertTrue(ledger.all().isEmpty)
    }

    /// 창이 떠 있으면 손대지 않는다. 항목도 파일도 그대로다.
    func test_openWindowLeavesEverything() throws {
        let a = store("a"), b = store("b")
        let z = try put(a, at: mark)
        try put(b, at: mark, name: "local_b.json")
        ledger.note("c1", from: "a", watermark: mark)

        sweep(windowsUp: ["a"], stores: ["a": [a], "b": [b]])

        XCTAssertTrue(FileManager.default.fileExists(atPath: z.path))
        XCTAssertEqual(ledger.all()["c1"]?.cleaned, 0)
    }

    /// 공유해 둔 대화는 항목만 빠진다. 파일은 공유의 것이다.
    func test_sharedConversationIsReleased() throws {
        let a = store("a"), b = store("b")
        let z = try put(a, at: mark)
        try put(b, at: mark, name: "local_b.json")
        ledger.note("c1", from: "a", watermark: mark)

        sweep(sharedIDs: ["c1"], stores: ["a": [a], "b": [b]])

        XCTAssertTrue(FileManager.default.fileExists(atPath: z.path))
        XCTAssertTrue(ledger.all().isEmpty)
    }

    /// 어느 계정에도 레코드가 없으면 옮김이 무효다. 항목만 빠진다.
    func test_vanishedMoveIsReleased() throws {
        let a = store("a"), b = store("b")
        try put(a, at: mark)
        try FileManager.default.createDirectory(at: b.root, withIntermediateDirectories: true)
        ledger.note("c1", from: "a", watermark: mark)

        sweep(stores: ["a": [a], "b": [b]])

        XCTAssertTrue(ledger.all().isEmpty)
    }

    /// **폴더가 안 변했으면 아무것도 안 읽는다.** 지난 바퀴의 mtime 을 주면
    /// 시체가 있어도 이번 바퀴는 지나간다. 빈 기억으로 다시 돌면 잡는다.
    func test_quietFolderIsSkipped() throws {
        let a = store("a"), b = store("b")
        let z = try put(a, at: mark)
        try put(b, at: mark, name: "local_b.json")
        ledger.note("c1", from: "a", watermark: mark)

        let seen = MoveJanitor.folderMarks(stores: ["a": [a], "b": [b]])
        sweep(stores: ["a": [a], "b": [b]], lastSeen: seen)
        XCTAssertTrue(FileManager.default.fileExists(atPath: z.path))

        sweep(stores: ["a": [a], "b": [b]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: z.path))
    }

    /// 돌려받은 기억을 다음 바퀴에 그대로 주면 조용한 폴더는 계속 건너뛴다.
    func test_returnedMarksKeepTheGateClosed() throws {
        let a = store("a"), b = store("b")
        try put(a, at: mark)
        try put(b, at: mark, name: "local_b.json")
        ledger.note("c1", from: "a", watermark: mark)

        let first = sweep(stores: ["a": [a], "b": [b]])
        XCTAssertFalse(first.isEmpty)
        // 우리 삭제가 mtime 을 움직였으므로 한 바퀴 더 돌아야 잠잠해진다
        let second = sweep(stores: ["a": [a], "b": [b]], lastSeen: first)
        let third = sweep(stores: ["a": [a], "b": [b]], lastSeen: second)
        XCTAssertEqual(second, third)
    }
}
