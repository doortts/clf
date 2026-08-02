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
        let s = SessionDuplicate.scan(stores: SessionDuplicate.stores(inside: root))
        XCTAssertEqual(s.map(\.transcriptID), ["c1"])
        XCTAssertEqual(s[0].accounts, ["A", "B"])
    }

    func test_cleanDiskFindsNothing() throws {
        try put("A", cli: "c1")
        try put("B", cli: "c2")
        XCTAssertEqual(SessionDuplicate.scan(stores: SessionDuplicate.stores(inside: root)), [])
    }

    /// 계정 이름을 알아야 어디가 겹쳤는지 말할 수 있다.
    func test_storeKnowsItsAccount() {
        XCTAssertEqual(SessionStore(dataDirectory: root, person: "p", account: "u1").account, "u1")
    }

    /// 찾아낸 것이 넘기기 목록까지 전달되는지.
    func test_summaryCarriesTheSharedFlag() throws {
        try put("A", cli: "c1")
        try put("B", cli: "c1")
        let ids = Set(SessionDuplicate.scan(stores: SessionDuplicate.stores(inside: root))
            .map(\.transcriptID))
        let rows = SessionStore(dataDirectory: root, person: "p", account: "A")
            .summaries(projects: root.appendingPathComponent("없다"), sharedTranscripts: ids)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].sharedRecord)
    }
}

/// 겹친 대화 중 **지금 쓰이고 있는 것**만 찾는다. 팝오버 경고가 그린다.
///
/// 한 폴더에 세션 여럿은 경고가 아니다. 사용자는 세션마다 워크트리를 갈라
/// 쓴다. 위험한 것은 서로 다른 계정의 창 둘이 한 대화에 같이 쓰는 것이다.
final class SessionDuplicateLiveTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    private func owner(_ account: String, _ cli: String,
                       activeAt: Date? = nil) -> SessionDuplicate.Owner {
        .init(account: account, fileName: "local_\(cli).json", transcriptID: cli,
              lastActivityAt: activeAt)
    }

    /// 두 계정이 가리키고 최근에 대화한 것만 경고다.
    func test_recentSharedConversationIsLive() {
        let live = SessionDuplicate.live([owner("A", "c1", activeAt: ago(60)),
                                          owner("B", "c1", activeAt: ago(500))],
                                         now: now, spokeAt: { _ in self.ago(60) })
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].transcriptID, "c1")
        XCTAssertEqual(live[0].owners.map(\.account), ["A", "B"])
    }

    /// 한 계정만 가리키면 규칙대로다. 아무리 바빠도 경고가 아니다.
    func test_oneAccountIsNotLive() {
        XCTAssertEqual(SessionDuplicate.live([owner("A", "c1")],
                                             now: now, spokeAt: { _ in self.ago(60) }), [])
    }

    /// 겹쳐 있어도 오래 안 쓴 대화는 조용히 둔다. doctor 가 다룰 일이다.
    func test_idleSharedConversationIsNotLive() {
        XCTAssertEqual(
            SessionDuplicate.live([owner("A", "c1"), owner("B", "c1")], now: now,
                                  spokeAt: { _ in self.ago(SessionDuplicate.liveWindow + 60) }),
            [])
    }

    /// 대화한 적이 없으면 쓰는 중이 아니다.
    func test_neverSpokeIsNotLive() {
        XCTAssertEqual(SessionDuplicate.live([owner("A", "c1"), owner("B", "c1")],
                                             now: now, spokeAt: { _ in nil }), [])
    }

    /// 한 계정 안의 레코드 둘은 계정 하나다.
    func test_twoRecordsInOneAccountAreNotLive() {
        XCTAssertEqual(SessionDuplicate.live([owner("A", "c1"), owner("A", "c1")],
                                             now: now, spokeAt: { _ in self.ago(60) }), [])
    }

    /// 화면은 계정마다 언제까지 썼는지 적는다. 최근 것이 먼저다.
    func test_ownersCarryActivityMostRecentFirst() {
        let live = SessionDuplicate.live([owner("A", "c1", activeAt: ago(600)),
                                          owner("B", "c1", activeAt: ago(60))],
                                         now: now, spokeAt: { _ in self.ago(60) })
        XCTAssertEqual(live[0].owners.map(\.account), ["B", "A"])
        XCTAssertEqual(live[0].owners.map(\.lastActivityAt), [ago(60), ago(600)])
    }

    /// 시각을 모르는 레코드는 뒤로 보낸다. 모르는 것이 앞에 서면 안 된다.
    func test_unknownActivityGoesLast() {
        let live = SessionDuplicate.live([owner("A", "c1"), owner("B", "c1", activeAt: ago(60))],
                                         now: now, spokeAt: { _ in self.ago(60) })
        XCTAssertEqual(live[0].owners.map(\.account), ["B", "A"])
    }

    /// 방금 넘긴 대화는 겹쳐 보여도 참는다. 사용자가 스스로 한 일이다.
    func test_mutedConversationIsNotReported() {
        let live = SessionDuplicate.live([owner("A", "c1"), owner("B", "c1")],
                                         now: now, muted: ["c1"],
                                         spokeAt: { _ in self.ago(60) })
        XCTAssertEqual(live, [])
    }

    /// 한 계정에 레코드가 둘이면 최근 시각 하나로 합친다. 계정은 한 줄이다.
    func test_oneSightingPerAccount() {
        let live = SessionDuplicate.live([owner("A", "c1", activeAt: ago(600)),
                                          owner("A", "c1", activeAt: ago(60)),
                                          owner("B", "c1", activeAt: ago(120))],
                                         now: now, spokeAt: { _ in self.ago(60) })
        XCTAssertEqual(live[0].owners.map(\.account), ["A", "B"])
        XCTAssertEqual(live[0].owners[0].lastActivityAt, ago(60))
    }
}

/// 세션 줄에 붙는 "어느 계정에서 언제까지" 설명.
final class SessionDuplicateWorkNoteTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// 1분이 안 지났으면 아직 일하는 중이다. "0분 전" 은 말이 아니다.
    func test_justNowReadsAsWorking() {
        XCTAssertEqual(SessionDuplicate.workNote(account: "NAVER_TEAM_52",
                                                 wroteAt: now.addingTimeInterval(-30), now: now),
                       "NAVER_TEAM_52 에서 지금 작업 중")
    }

    func test_minutesAgo() {
        XCTAssertEqual(SessionDuplicate.workNote(account: "NAVER_TEAM_40",
                                                 wroteAt: now.addingTimeInterval(-7 * 60 - 20),
                                                 now: now),
                       "NAVER_TEAM_40 에서 7분 전까지 작업")
    }

    /// 시계가 어긋나 미래로 찍혀도 "지금" 으로 말한다.
    func test_futureReadsAsWorking() {
        XCTAssertEqual(SessionDuplicate.workNote(account: "A",
                                                 wroteAt: now.addingTimeInterval(600), now: now),
                       "A 에서 지금 작업 중")
    }

    /// 시각을 모르면 계정만 말한다. 지어낸 시각보다 낫다.
    func test_unknownTimeSaysAccountOnly() {
        XCTAssertEqual(SessionDuplicate.workNote(account: "A", wroteAt: nil, now: now), "A")
        XCTAssertEqual(SessionDuplicate.workNote(account: nil,
                                                 wroteAt: now.addingTimeInterval(-120), now: now),
                       "2분 전까지 작업")
        XCTAssertEqual(SessionDuplicate.workNote(account: nil, wroteAt: nil, now: now), "")
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

/// 실제 파일로 "지금 쓰이는 겹침" 을 훑는다.
final class SessionDuplicateLiveScanTests: XCTestCase {
    private var root: URL!
    private var projects: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-live-\(UUID().uuidString)")
        projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func put(_ account: String, cli: String, activeAt: Date? = nil) throws {
        let s = SessionStore(dataDirectory: root, person: "p", account: account)
        try FileManager.default.createDirectory(at: s.root, withIntermediateDirectories: true)
        let active = activeAt.map { ",\"lastActivityAt\":\($0.timeIntervalSince1970 * 1000)" } ?? ""
        try Data(#"{"sessionId":"s","cliSessionId":"\#(cli)"\#(active)}"#.utf8)
            .write(to: s.root.appendingPathComponent("local_\(account)-\(cli).json"))
    }

    /// 트랜스크립트를 이 내용으로 만든다. 이미 있으면 갈아 끼운다.
    private func transcript(_ cli: String, lines: [String]) throws {
        let dir = projects.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: dir.appendingPathComponent("\(cli).jsonl"))
    }

    private func iso(secondsAgo: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(-secondsAgo))
    }

    private func scan() -> [SessionDuplicate.Live] {
        SessionDuplicate.scanLive(stores: SessionDuplicate.stores(inside: root),
                                  projects: projects)
    }

    func test_findsASharedConversationInUse() throws {
        try put("A", cli: "c1", activeAt: Date().addingTimeInterval(-60))
        try put("B", cli: "c1", activeAt: Date().addingTimeInterval(-300))
        try transcript("c1", lines: [#"{"type":"user","timestamp":"\#(iso(secondsAgo: 60))"}"#])
        let live = scan()
        XCTAssertEqual(live.map(\.transcriptID), ["c1"])
        XCTAssertEqual(live[0].owners.map(\.account), ["A", "B"])
        XCTAssertEqual(live[0].owners.compactMap(\.lastActivityAt).count, 2)
    }

    /// 계정이 갈라 쓰는 대화가 아니면 조용하다. 평소가 이 상태다.
    func test_separateConversationsAreQuiet() throws {
        try put("A", cli: "c1")
        try put("B", cli: "c2")
        try transcript("c1", lines: [#"{"type":"user","timestamp":"\#(iso(secondsAgo: 60))"}"#])
        try transcript("c2", lines: [#"{"type":"user","timestamp":"\#(iso(secondsAgo: 60))"}"#])
        XCTAssertEqual(scan(), [])
    }

    /// **메타데이터가 붙었다고 쓰는 중이 아니다.** 데스크톱 앱은 창이 떠
    /// 있으면 놀고 있는 세션에도 last-prompt, ai-title 줄을 계속 덧붙인다.
    /// 실측에서 대화가 00:59 에 끝난 세션의 mtime 이 03:44 였다.
    func test_appendedMetadataDoesNotMakeItLive() throws {
        try put("A", cli: "c1")
        try put("B", cli: "c1")
        try transcript("c1", lines: [
            #"{"type":"assistant","timestamp":"\#(iso(secondsAgo: 3 * 3600))"}"#,
            #"{"type":"last-prompt","lastPrompt":"선을 없애줘"}"#,
            #"{"type":"ai-title","aiTitle":"Clauly GUI 도구 기술 스택"}"#,
        ])
        XCTAssertEqual(scan(), [])
    }

    /// 초 단위 timestamp 도 읽는다. CLI 가 소수점을 안 붙일 때가 있다.
    func test_readsWholeSecondTimestamps() throws {
        try put("A", cli: "c1")
        try put("B", cli: "c1")
        let f = ISO8601DateFormatter()
        try transcript("c1", lines: [
            #"{"type":"user","timestamp":"\#(f.string(from: Date().addingTimeInterval(-60)))"}"#,
        ])
        XCTAssertEqual(scan().count, 1)
    }

    /// **mtime 이 오래된 파일은 열지 않는다.** 훑기는 세션마다 도는데 지난
    /// 세션까지 다 열면 비싸다. mtime 은 마지막 쓰기의 상한이다.
    func test_staleFilesAreJudgedByMtimeWithoutOpening() throws {
        try transcript("c1", lines: [#"{"type":"user","timestamp":"\#(iso(secondsAgo: 0))"}"#])
        let url = projects.appendingPathComponent("proj/c1.jsonl")
        let old = Date().addingTimeInterval(-SessionDuplicate.liveWindow - 600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        let at = SessionDuplicate.writtenAt("c1", projects: projects, now: Date())
        XCTAssertEqual(at.map { abs($0.timeIntervalSince(old)) < 1 }, true)
    }

    /// 제목은 트랜스크립트 양끝에서 읽는다. 못 읽으면 자리 표시로 말한다.
    func test_titlesComeFromTranscripts() throws {
        try transcript("c1", lines: [#"{"aiTitle":"게이지 방향 작업"}"#])
        XCTAssertEqual(SessionDuplicate.titles(ids: ["c1", "없는세션"], projects: projects),
                       ["게이지 방향 작업", SessionDuplicate.untitled])
    }

    /// 계정 폴더는 디렉토리를 읽어서 안다. 계정 목록을 안 넘겨도 된다.
    func test_findsAccountFoldersByReadingTheDirectory() throws {
        try put("A", cli: "c1")
        try put("B", cli: "c2")
        XCTAssertEqual(SessionDuplicate.stores(inside: root).map(\.account), ["A", "B"])
    }

    func test_emptyDataDirectoryHasNoStores() {
        XCTAssertEqual(SessionDuplicate.stores(inside: root.appendingPathComponent("없다")).count, 0)
    }
}
