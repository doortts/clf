import XCTest
@testable import ClflDesktop

/// 한 작업 폴더에 세션이 여럿 붙어 있는 것을 찾는다.
///
/// 넘기기는 이 상황을 못 막는다. 레코드만 옮기고 체크아웃은 그대로 두기
/// 때문이다. docs/design/13-multi-instance.md 12절
final class FolderOverlapTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    private func find(_ uses: [FolderOverlap.Use]) -> [FolderOverlap.Folder] {
        FolderOverlap.find(uses, now: now)
    }

    /// 혼자 쓰는 폴더는 겹친 것이 아니다. 평소가 이 상태다.
    func test_oneSessionIsNotAnOverlap() {
        XCTAssertEqual(find([.init(cwd: "/repo", wroteAt: ago(60))]), [])
    }

    func test_twoSessionsInOneFolder() {
        let f = find([.init(cwd: "/repo", wroteAt: ago(60)),
                      .init(cwd: "/repo", wroteAt: ago(120))])
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].path, "/repo")
        XCTAssertEqual(f[0].sessions, 2)
        XCTAssertEqual(f[0].name, "repo")
    }

    /// 다른 폴더끼리는 안 겹친다. 폴더가 단위다.
    func test_differentFoldersDoNotOverlap() {
        XCTAssertEqual(find([.init(cwd: "/a", wroteAt: ago(60)),
                             .init(cwd: "/b", wroteAt: ago(60))]), [])
    }

    /// 오래 전에 쓴 세션은 안 센다. 지난 세션까지 세면 늘 겹친 것으로 보인다.
    func test_ignoresOldSessions() {
        XCTAssertEqual(find([.init(cwd: "/repo", wroteAt: ago(60)),
                             .init(cwd: "/repo", wroteAt: ago(FolderOverlap.liveWindow + 60))]), [])
    }

    /// 트랜스크립트가 없으면 쓴 적이 없다.
    func test_ignoresSessionsThatNeverWrote() {
        XCTAssertEqual(find([.init(cwd: "/repo", wroteAt: ago(60)),
                             .init(cwd: "/repo", wroteAt: nil)]), [])
    }

    /// 경로를 모르면 셀 수 없다.
    func test_ignoresUnknownFolders() {
        XCTAssertEqual(find([.init(cwd: "", wroteAt: ago(60)),
                             .init(cwd: "", wroteAt: ago(60))]), [])
    }

    /// 시계가 어긋나 미래로 찍힐 수 있다. 그것도 최근으로 본다.
    func test_futureCountsAsRecent() {
        XCTAssertEqual(find([.init(cwd: "/repo", wroteAt: ago(-600)),
                             .init(cwd: "/repo", wroteAt: ago(60))]).count, 1)
    }

    /// 바쁜 폴더가 위로. 같으면 경로 순서로 고정한다.
    func test_sortsBusiestFirst() {
        let f = find([.init(cwd: "/two", wroteAt: ago(1)), .init(cwd: "/two", wroteAt: ago(2)),
                      .init(cwd: "/three", wroteAt: ago(1)), .init(cwd: "/three", wroteAt: ago(2)),
                      .init(cwd: "/three", wroteAt: ago(3))])
        XCTAssertEqual(f.map(\.path), ["/three", "/two"])
    }

    /// "세션 2" 같은 개수는 무엇인지 말해주지 않는다. 제목으로 말하려면
    /// 폴더가 겹친 세션의 id 를 들고 있어야 한다. 최근 것이 먼저다.
    func test_folderKeepsItsSessionsMostRecentFirst() {
        let f = find([.init(id: "old", cwd: "/repo", wroteAt: ago(120)),
                      .init(id: "new", cwd: "/repo", wroteAt: ago(60))])
        XCTAssertEqual(f[0].sessionIDs, ["new", "old"])
        XCTAssertEqual(f[0].sessions, 2)
    }
}

/// 실제 파일을 훑는다.
final class FolderOverlapScanTests: XCTestCase {
    private var root: URL!
    private var data: URL!
    private var projects: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlap-\(UUID().uuidString)")
        data = root.appendingPathComponent("Data")
        projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func store(_ account: String) -> SessionStore {
        SessionStore(dataDirectory: data, person: "p", account: account)
    }

    private func put(_ account: String, cli: String, cwd: String) throws {
        let s = store(account)
        try FileManager.default.createDirectory(at: s.root, withIntermediateDirectories: true)
        try Data(#"{"sessionId":"s","cliSessionId":"\#(cli)","cwd":"\#(cwd)"}"#.utf8)
            .write(to: s.root.appendingPathComponent("local_\(cli).json"))
        // 방금 대화한 트랜스크립트. 살았는지는 대화 줄의 timestamp 로 판정한다
        try transcript(cli, lines: [#"{"type":"user","timestamp":"\#(iso(secondsAgo: 60))"}"#])
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

    func test_findsAnOverlapAcrossAccounts() throws {
        try put("A", cli: "c1", cwd: "/repo")
        try put("B", cli: "c2", cwd: "/repo")
        let f = FolderOverlap.scan(stores: FolderOverlap.stores(inside: data), projects: projects)
        XCTAssertEqual(f.map(\.sessions), [2])
    }

    /// **같은 대화가 계정 폴더 둘에 있으면 한 번만 센다.** 지금 디스크가
    /// 실제로 그 상태다. 두 번 세면 겹치지도 않은 폴더가 겹친 것으로 보인다.
    func test_countsOneConversationOnce() throws {
        try put("A", cli: "c1", cwd: "/repo")
        try put("B", cli: "c1", cwd: "/repo")
        XCTAssertEqual(FolderOverlap.scan(stores: FolderOverlap.stores(inside: data),
                                          projects: projects), [])
    }

    /// 계정 폴더는 디렉토리를 읽어서 안다. 계정 목록을 안 넘겨도 된다.
    func test_findsAccountFoldersByReadingTheDirectory() throws {
        try put("A", cli: "c1", cwd: "/repo")
        try put("B", cli: "c2", cwd: "/repo")
        XCTAssertEqual(FolderOverlap.stores(inside: data).map(\.root),
                       [store("A").root, store("B").root])
    }

    func test_emptyDataDirectoryHasNoStores() {
        XCTAssertEqual(FolderOverlap.stores(inside: root.appendingPathComponent("없다")).count, 0)
    }

    func test_scanCarriesSessionIDs() throws {
        try put("A", cli: "c1", cwd: "/repo")
        try put("B", cli: "c2", cwd: "/repo")
        let f = FolderOverlap.scan(stores: FolderOverlap.stores(inside: data), projects: projects)
        XCTAssertEqual(Set(f[0].sessionIDs), ["c1", "c2"])
    }

    /// **메타데이터가 붙었다고 살아 있는 세션이 아니다.** 데스크톱 앱은 창이
    /// 떠 있으면 놀고 있는 세션에도 `last-prompt`, `ai-title` 줄을 계속
    /// 덧붙인다. 실측에서 대화가 00:59 에 끝난 세션의 mtime 이 03:44 였다.
    /// 대화 줄에만 timestamp 가 있으므로 그것으로 판정한다.
    func test_appendedMetadataDoesNotMakeASessionLive() throws {
        try put("A", cli: "c1", cwd: "/repo")
        try put("B", cli: "c2", cwd: "/repo")
        try transcript("c2", lines: [
            #"{"type":"assistant","timestamp":"\#(iso(secondsAgo: 3 * 3600))"}"#,
            #"{"type":"last-prompt","lastPrompt":"선을 없애줘"}"#,
            #"{"type":"ai-title","aiTitle":"Clauly GUI 도구 기술 스택"}"#,
        ])
        XCTAssertEqual(FolderOverlap.scan(stores: FolderOverlap.stores(inside: data),
                                          projects: projects), [])
    }

    /// 대화 줄이 하나도 없으면 쓴 적이 없는 세션이다.
    func test_transcriptWithoutConversationIsNotLive() throws {
        try put("A", cli: "c1", cwd: "/repo")
        try put("B", cli: "c2", cwd: "/repo")
        try transcript("c2", lines: ["{}"])
        XCTAssertEqual(FolderOverlap.scan(stores: FolderOverlap.stores(inside: data),
                                          projects: projects), [])
    }

    /// 초 단위 timestamp 도 읽는다. CLI 가 소수점을 안 붙일 때가 있다.
    func test_readsWholeSecondTimestamps() throws {
        try put("A", cli: "c1", cwd: "/repo")
        try put("B", cli: "c2", cwd: "/repo")
        let f = ISO8601DateFormatter()
        try transcript("c2", lines: [
            #"{"type":"user","timestamp":"\#(f.string(from: Date().addingTimeInterval(-60)))"}"#,
        ])
        XCTAssertEqual(FolderOverlap.scan(stores: FolderOverlap.stores(inside: data),
                                          projects: projects).map(\.sessions), [2])
    }

    /// **mtime 이 오래된 파일은 열지 않는다.** 훑기는 계정의 모든 세션을
    /// 도는데, 지난 세션까지 다 열면 비싸다. mtime 은 마지막 쓰기의 상한이라
    /// 오래됐으면 내용도 오래됐다.
    func test_staleFilesAreJudgedByMtimeWithoutOpening() throws {
        try put("A", cli: "c1", cwd: "/repo")
        try transcript("c1", lines: [#"{"type":"user","timestamp":"\#(iso(secondsAgo: 0))"}"#])
        let url = projects.appendingPathComponent("proj/c1.jsonl")
        let old = Date().addingTimeInterval(-FolderOverlap.liveWindow - 600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        let at = FolderOverlap.writtenAt("c1", projects: projects, now: Date())
        XCTAssertEqual(at.map { abs($0.timeIntervalSince(old)) < 1 }, true)
    }

    /// 제목은 트랜스크립트 양끝에서 읽는다. 못 읽으면 자리 표시로 말한다.
    /// 빈 배지("세션 2")보다 제목이 어느 창인지 알려준다.
    func test_titlesComeFromTranscripts() throws {
        try put("A", cli: "c1", cwd: "/repo")
        try Data(#"{"aiTitle":"게이지 방향 작업"}"#.utf8)
            .write(to: projects.appendingPathComponent("proj/c1.jsonl"))
        XCTAssertEqual(FolderOverlap.titles(ids: ["c1", "없는세션"], projects: projects),
                       ["게이지 방향 작업", FolderOverlap.untitled])
    }
}
