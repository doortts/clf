import XCTest
@testable import ClfDesktop

/// 공유한 대화의 레코드를 최신본으로 맞춘다.
///
/// 레코드는 턴마다 바뀌지만 그 변화가 뜻을 가지는 순간은 계정을 바꿀 때뿐이다.
/// 그래서 창이 떠 있는 계정에만 쓰고, 대상이 더 최신이거나 같으면 안 쓴다.
/// 이 둘이 쓰기 폭풍을 막는 자리다. docs/design/14-shared-session.md 5절
final class SharedSyncPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func side(_ account: String, _ minutes: Double?) -> SharedSync.Side {
        SharedSync.Side(account: account, fileName: "local_\(account).json",
                        lastActivityAt: minutes.map { now.addingTimeInterval($0 * 60) })
    }

    func test_newestRecordIsTheSource() {
        let plan = SharedSync.plan([side("a", 0), side("b", -30)], windowsUp: ["a", "b"])
        XCTAssertEqual(plan.map(\.to), ["b"])
        XCTAssertEqual(plan.first?.from.account, "a")
        XCTAssertEqual(plan.first?.from.fileName, "local_a.json")
    }

    /// **창이 없는 계정에는 안 쓴다.** 그 목록을 읽을 프로세스가 없다.
    /// 이 문이 없으면 한 계정으로 일하는 내내 턴마다 반대쪽 폴더에 쓴다.
    func test_skipsAccountsWithoutAWindow() {
        XCTAssertTrue(SharedSync.plan([side("a", 0), side("b", -30)], windowsUp: ["a"]).isEmpty)
    }

    /// 대상이 더 최신이면 안 쓴다. 되돌림 사고다.
    func test_neverGoesBackwards() {
        let plan = SharedSync.plan([side("a", -30), side("b", 0)], windowsUp: ["a", "b"])
        XCTAssertEqual(plan.map(\.to), ["a"])
    }

    /// **시각이 같으면 안 쓴다.** 우리가 쓴 값이 다음 바퀴에 다시 최신으로
    /// 보이므로, 여기서 안 끊으면 두 폴더를 무한히 오간다.
    func test_equalActivityIsNothingToDo() {
        XCTAssertTrue(SharedSync.plan([side("a", 0), side("b", 0)], windowsUp: ["a", "b"]).isEmpty)
    }

    /// 시각을 모르는 레코드는 옛것으로 친다. 받는 쪽은 되고 주는 쪽은 안 된다.
    func test_unknownActivityReceivesButNeverSends() {
        let plan = SharedSync.plan([side("a", -30), side("b", nil)], windowsUp: ["a", "b"])
        XCTAssertEqual(plan.map(\.to), ["b"])
    }

    /// 아무도 시각을 모르면 누가 최신인지 말할 수 없다. 손대지 않는다.
    func test_allUnknownDoesNothing() {
        XCTAssertTrue(SharedSync.plan([side("a", nil), side("b", nil)],
                                      windowsUp: ["a", "b"]).isEmpty)
    }

    /// 계정이 셋이면 최신 하나가 나머지 둘에 간다. 순서는 계정 이름으로 고정한다.
    func test_oneSourceFeedsTheRest() {
        let plan = SharedSync.plan([side("c", 0), side("a", -30), side("b", -10)],
                                   windowsUp: ["a", "b", "c"])
        XCTAssertEqual(plan.map(\.to), ["a", "b"])
        XCTAssertEqual(Set(plan.map(\.from.account)), ["c"])
    }

    /// 한 계정 안에 레코드가 둘이어도 계정은 하나다. 최신 것만 본다.
    func test_oneAccountCountsOnce() {
        let two = [SharedSync.Side(account: "a", fileName: "local_old.json",
                                   lastActivityAt: now.addingTimeInterval(-600)),
                   SharedSync.Side(account: "a", fileName: "local_new.json",
                                   lastActivityAt: now)]
        let plan = SharedSync.plan(two + [side("b", -30)], windowsUp: ["a", "b"])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.from.fileName, "local_new.json")
    }

    func test_oneSideIsNotShared() {
        XCTAssertTrue(SharedSync.plan([side("a", 0)], windowsUp: ["a"]).isEmpty)
    }
}

/// 디스크에 실제로 쓰는 쪽.
final class SharedSyncRunTests: XCTestCase {
    private var root: URL!
    private var ledger: SharedSessions!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ledger = try SharedSessions(directory: root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func store(_ account: String, dir: String = "primary") -> SessionStore {
        SessionStore(dataDirectory: root.appendingPathComponent(dir), person: "p", account: account)
    }

    @discardableResult
    private func put(_ store: SessionStore, _ name: String, cli: String = "c1",
                     at: Date?, title: String = "제목") throws -> URL {
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let stamp = at.map { "\($0.timeIntervalSince1970 * 1000)" } ?? "null"
        let url = store.root.appendingPathComponent(name)
        try Data(#"{"cliSessionId":"\#(cli)","lastActivityAt":\#(stamp),"title":"\#(title)"}"#.utf8)
            .write(to: url)
        return url
    }

    private func title(_ store: SessionStore, _ name: String) -> String? {
        guard let data = FileManager.default
                .contents(atPath: store.root.appendingPathComponent(name).path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["title"] as? String
    }

    /// 최신본이 옛 사본을 덮는다. **파일 이름은 대상 것을 지킨다.**
    /// 이름까지 바꾸면 앱 목록에서 그 줄이 사라진다.
    func test_newestOverwritesTheOlderCopy() throws {
        let a = store("a"), b = store("b")
        try put(a, "local_aaa.json", at: now, title: "새 제목")
        try put(b, "local_bbb.json", at: now.addingTimeInterval(-600), title: "옛 제목")
        ledger.share("c1", accounts: ["a", "b"], at: now)

        let copied = SharedSync.run(ledger, stores: ["a": [a], "b": [b]], windowsUp: ["a", "b"])

        XCTAssertEqual(copied, 1)
        XCTAssertEqual(b.fileNames(), ["local_bbb.json"])
        XCTAssertEqual(title(b, "local_bbb.json"), "새 제목")
    }

    /// 창이 없는 계정은 건드리지 않는다.
    func test_leavesWindowlessAccountsAlone() throws {
        let a = store("a"), b = store("b")
        try put(a, "local_aaa.json", at: now, title: "새 제목")
        try put(b, "local_bbb.json", at: now.addingTimeInterval(-600), title: "옛 제목")
        ledger.share("c1", accounts: ["a", "b"], at: now)

        XCTAssertEqual(SharedSync.run(ledger, stores: ["a": [a], "b": [b]], windowsUp: ["a"]), 0)
        XCTAssertEqual(title(b, "local_bbb.json"), "옛 제목")
    }

    /// 한 계정의 자리가 여럿이면 다 맞춘다. 별도 창이 옛것을 계속 보여주면 안 된다.
    func test_fillsEverySiteOfTheAccount() throws {
        let a = store("a"), b = store("b"), altB = store("b", dir: "alt")
        try put(a, "local_aaa.json", at: now, title: "새 제목")
        try put(b, "local_bbb.json", at: now.addingTimeInterval(-600), title: "옛 제목")
        try put(altB, "local_ccc.json", at: now.addingTimeInterval(-600), title: "옛 제목")
        ledger.share("c1", accounts: ["a", "b"], at: now)

        SharedSync.run(ledger, stores: ["a": [a], "b": [b, altB]], windowsUp: ["a", "b"])

        XCTAssertEqual(title(b, "local_bbb.json"), "새 제목")
        XCTAssertEqual(title(altB, "local_ccc.json"), "새 제목")
    }

    /// 그 자리에 아직 레코드가 없으면 원본 이름으로 넣는다.
    func test_missingSiteGetsTheSourceName() throws {
        let a = store("a"), b = store("b"), altB = store("b", dir: "alt")
        try FileManager.default.createDirectory(at: altB.root, withIntermediateDirectories: true)
        try put(a, "local_aaa.json", at: now, title: "새 제목")
        try put(b, "local_bbb.json", at: now.addingTimeInterval(-600), title: "옛 제목")
        ledger.share("c1", accounts: ["a", "b"], at: now)

        SharedSync.run(ledger, stores: ["a": [a], "b": [b, altB]], windowsUp: ["a", "b"])

        XCTAssertEqual(altB.fileNames(), ["local_aaa.json"])
    }

    /// 우리가 써 넣은 값을 장부에 남긴다. 겹침 판정이 이 값으로 가짜 활동을 뺀다.
    func test_recordsTheWatermark() throws {
        let a = store("a"), b = store("b")
        try put(a, "local_aaa.json", at: now)
        try put(b, "local_bbb.json", at: now.addingTimeInterval(-600))
        ledger.share("c1", accounts: ["a", "b"], at: now)

        SharedSync.run(ledger, stores: ["a": [a], "b": [b]], windowsUp: ["a", "b"])

        let stamp = try XCTUnwrap(ledger.mirrorStamps()["c1"]?["b"])
        XCTAssertEqual(stamp.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
    }

    /// 두 번 돌아도 한 번만 쓴다. 첫 바퀴 뒤에는 두 쪽 시각이 같아진다.
    func test_secondPassDoesNothing() throws {
        let a = store("a"), b = store("b")
        try put(a, "local_aaa.json", at: now)
        try put(b, "local_bbb.json", at: now.addingTimeInterval(-600))
        ledger.share("c1", accounts: ["a", "b"], at: now)

        let first = SharedSync.run(ledger, stores: ["a": [a], "b": [b]], windowsUp: ["a", "b"])
        let second = SharedSync.run(ledger, stores: ["a": [a], "b": [b]], windowsUp: ["a", "b"])
        XCTAssertEqual([first, second], [1, 0])
    }

    /// 한쪽에서 대화를 지우면 그 계정을 목록에서 뺀다. 하나 남으면 항목이 사라진다.
    func test_deletedRecordLeavesTheList() throws {
        let a = store("a"), b = store("b")
        try put(a, "local_aaa.json", at: now)
        try FileManager.default.createDirectory(at: b.root, withIntermediateDirectories: true)
        ledger.share("c1", accounts: ["a", "b"], at: now)

        SharedSync.run(ledger, stores: ["a": [a], "b": [b]], windowsUp: ["a", "b"])

        XCTAssertTrue(ledger.all().isEmpty)
    }

    /// 공유 목록에 없는 대화는 손대지 않는다. 같은 폴더에 다른 세션이 많다.
    func test_ignoresConversationsOutsideTheList() throws {
        let a = store("a"), b = store("b")
        try put(a, "local_aaa.json", cli: "other", at: now, title: "새 제목")
        try put(b, "local_bbb.json", cli: "other", at: now.addingTimeInterval(-600),
                title: "옛 제목")

        XCTAssertEqual(SharedSync.run(ledger, stores: ["a": [a], "b": [b]],
                                      windowsUp: ["a", "b"]), 0)
        XCTAssertEqual(title(b, "local_bbb.json"), "옛 제목")
    }
}
