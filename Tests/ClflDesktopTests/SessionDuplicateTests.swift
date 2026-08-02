import XCTest
@testable import ClflDesktop

/// 한 대화를 여러 계정이 가리키는 것을 찾는다.
///
/// 11절이 정한 규칙은 **한 대화를 한 계정만 가리키는 것**이다. 옮기기는 먼저
/// 넣고 나중에 지우므로 이 상태를 만들지 않는다. 그런데 지금 디스크가 그
/// 규칙을 어기고 있고 아무도 안 잡는다. 규칙이 주석과 문서에만 있어서다.
/// docs/design/13-multi-instance.md 12절
final class SessionDuplicateTests: XCTestCase {
    private func owner(_ account: String, _ cli: String,
                       _ file: String = "local_x.json") -> SessionDuplicate.Owner {
        .init(account: account, fileName: file, transcriptID: cli)
    }

    /// 한 계정만 가리키면 규칙을 지킨 것이다. 평소가 이 상태다.
    func test_oneAccountIsFine() {
        XCTAssertEqual(SessionDuplicate.find([owner("A", "c1")]), [])
    }

    func test_findsTwoAccountsOnOneConversation() {
        let s = SessionDuplicate.find([owner("A", "c1"), owner("B", "c1")])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].transcriptID, "c1")
        XCTAssertEqual(s[0].accounts, ["A", "B"])
    }

    /// 다른 대화끼리는 상관없다. 대화가 단위다.
    func test_differentConversationsAreFine() {
        XCTAssertEqual(SessionDuplicate.find([owner("A", "c1"), owner("B", "c2")]), [])
    }

    /// 한 계정 안에 레코드가 둘이어도 계정은 하나다. 규칙을 어긴 것이 아니다.
    func test_twoRecordsInOneAccountIsNotADuplicate() {
        XCTAssertEqual(SessionDuplicate.find([owner("A", "c1", "local_x.json"),
                                              owner("A", "c1", "local_y.json")]), [])
    }

    /// 계정 이름은 정렬해서 돌려준다. 같은 상태가 늘 같게 보여야 한다.
    func test_sortsAccountsAndConversations() {
        let s = SessionDuplicate.find([owner("B", "c2"), owner("A", "c2"),
                                       owner("C", "c1"), owner("A", "c1")])
        XCTAssertEqual(s.map(\.transcriptID), ["c1", "c2"])
        XCTAssertEqual(s[0].accounts, ["A", "C"])
    }

    func test_threeAccountsAreAllReported() {
        XCTAssertEqual(SessionDuplicate.find([owner("A", "c1"), owner("B", "c1"),
                                              owner("C", "c1")])[0].accounts, ["A", "B", "C"])
    }
}

/// doctor 에 나갈 한 줄. 상태만 찍지 않고 무엇을 하면 풀리는지 같이 적는다.
final class SessionDuplicateDetailTests: XCTestCase {
    private func shared(_ ids: [String]) -> [SessionDuplicate.Shared] {
        ids.map { .init(transcriptID: $0, accounts: ["A", "B"]) }
    }

    func test_saysNothingIsWrong() {
        XCTAssertEqual(SessionDuplicate.detail([]), SessionDuplicate.clean)
    }

    func test_countsAndTellsWhatToDo() {
        let d = SessionDuplicate.detail(shared(["c1"]))
        XCTAssertTrue(d.contains("1개"))
        XCTAssertTrue(d.contains("지운다"))
    }

    /// 어느 대화인지 알려줘야 손을 댈 수 있다. 다만 표 한 칸이라 앞만 적는다.
    func test_namesTheConversationsButNotAllOfThem() {
        let d = SessionDuplicate.detail(shared(["c1", "c2", "c3"]), limit: 2)
        XCTAssertTrue(d.contains("c1"))
        XCTAssertTrue(d.contains("c2"))
        XCTAssertFalse(d.contains("c3"))
        XCTAssertTrue(d.contains("외 1개"))
    }

    /// 표 한 칸에 uuid 를 통째로 넣으면 줄이 화면을 넘는다. 앞 8자면 구분된다.
    func test_shortensLongIds() {
        let d = SessionDuplicate.detail(shared(["6fcb1fa1-6864-4749-865c-95c2559d0cfa"]))
        XCTAssertTrue(d.contains("6fcb1fa1"))
        XCTAssertFalse(d.contains("6864"))
    }

    /// 다 적을 수 있으면 "외 N개" 를 붙이지 않는다.
    func test_noTailWhenEverythingFits() {
        XCTAssertFalse(SessionDuplicate.detail(shared(["c1"]), limit: 2).contains("외"))
    }
}

/// 실제 파일을 훑는다.
final class SessionDuplicateScanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func put(_ account: String, cli: String, file: String? = nil) throws {
        let s = SessionStore(dataDirectory: root, person: "p", account: account)
        try FileManager.default.createDirectory(at: s.root, withIntermediateDirectories: true)
        try Data(#"{"sessionId":"s","cliSessionId":"\#(cli)"}"#.utf8)
            .write(to: s.root.appendingPathComponent(file ?? "local_\(cli).json"))
    }

    /// 지금 디스크가 이 상태다. 같은 대화가 두 계정 폴더에 다 있다.
    func test_findsTheRealShape() throws {
        try put("A", cli: "c1")
        try put("B", cli: "c1")
        try put("A", cli: "c2")
        let s = SessionDuplicate.scan(stores: FolderOverlap.stores(inside: root))
        XCTAssertEqual(s.map(\.transcriptID), ["c1"])
        XCTAssertEqual(s[0].accounts, ["A", "B"])
    }

    func test_cleanDiskFindsNothing() throws {
        try put("A", cli: "c1")
        try put("B", cli: "c2")
        XCTAssertEqual(SessionDuplicate.scan(stores: FolderOverlap.stores(inside: root)), [])
    }

    /// 계정 이름을 알아야 어디가 겹쳤는지 말할 수 있다.
    func test_storeKnowsItsAccount() {
        XCTAssertEqual(SessionStore(dataDirectory: root, person: "p", account: "u1").account, "u1")
    }

    /// 찾아낸 것이 넘기기 목록까지 전달되는지.
    func test_summaryCarriesTheSharedFlag() throws {
        try put("A", cli: "c1")
        try put("B", cli: "c1")
        let ids = Set(SessionDuplicate.scan(stores: FolderOverlap.stores(inside: root))
            .map(\.transcriptID))
        let rows = SessionStore(dataDirectory: root, person: "p", account: "A")
            .summaries(projects: root.appendingPathComponent("없다"), sharedTranscripts: ids)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].sharedRecord)
    }
}

/// 넘기기 창에서 왜 막히는지 그 자리에서 말한다.
///
/// doctor 는 원인을 찾는 자리고 이쪽은 사용자가 마주치는 자리다. 팝오버로만
/// 일하는 사용자는 doctor 를 볼 일이 없다.
final class SharedRecordWarningTests: XCTestCase {
    private func summary(transcript: Bool = true, folder: Bool = true,
                         shared: Bool = false) -> SessionSummary {
        .init(fileName: "local_x.json", cliSessionID: "c1", title: "t", folder: "repo",
              lastActivityAt: nil, hasTranscript: transcript, folderExists: folder,
              sharedRecord: shared)
    }

    func test_saysWhenTwoAccountsPointAtIt() {
        XCTAssertEqual(summary(shared: true).warning, SessionSummary.sharedByAccounts)
    }

    /// 겹침이 폴더 없음보다 앞이다. 옮기기가 실제로 막힐 수 있는 쪽이다.
    func test_sharedBeatsMissingFolder() {
        XCTAssertEqual(summary(folder: false, shared: true).warning,
                       SessionSummary.sharedByAccounts)
    }

    /// 기록이 아예 없는 것은 여전히 제일 큰 문제다.
    func test_missingTranscriptStillWins() {
        XCTAssertEqual(summary(transcript: false, shared: true).warning,
                       SessionSummary.noTranscript)
    }

    func test_nothingSharedNothingSaid() {
        XCTAssertNil(summary().warning)
    }
}
