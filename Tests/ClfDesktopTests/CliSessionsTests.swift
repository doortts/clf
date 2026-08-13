import XCTest
@testable import ClfDesktop

/// CLI 세션 목록 읽기. 임시 디렉토리에 기록을 흉내 내 둔다.
final class CliSessionsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ id: String, project: String, lines: [String],
                       at date: Date? = nil) throws -> URL {
        let dir = root.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        if let date {
            try FileManager.default.setAttributes([.modificationDate: date],
                                                  ofItemAtPath: url.path)
        }
        return url
    }

    func testReadsTitleAndCwd() throws {
        try write("aaa", project: "-Users-me-repo", lines: [
            #"{"type":"custom-title","customTitle":"Build 스크립트 작성"}"#,
            #"{"type":"mode","mode":"normal"}"#,
            #"{"type":"user","cwd":"/Users/me/repo","message":{"role":"user","content":"안녕"}}"#,
        ])
        let sessions = CliSessions.scan(root: root)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "aaa")
        XCTAssertEqual(sessions[0].title, "Build 스크립트 작성")
        XCTAssertEqual(sessions[0].cwd, "/Users/me/repo")
    }

    /// 제목을 안 정한 세션은 첫 물음이 제목이다.
    func testFallsBackToFirstUserMessage() throws {
        try write("bbb", project: "-p", lines: [
            #"{"type":"mode","mode":"normal"}"#,
            #"{"type":"user","cwd":"/tmp/x","message":{"role":"user","content":"리밋 풀리면 재개해줘"}}"#,
        ])
        XCTAssertEqual(CliSessions.scan(root: root).first?.title, "리밋 풀리면 재개해줘")
    }

    /// 블록 배열로 온 본문도 읽는다.
    func testReadsContentBlocks() throws {
        try write("ccc", project: "-p", lines: [
            #"{"type":"user","cwd":"/tmp/x","message":{"role":"user","content":[{"type":"text","text":"블록으로 온 물음"}]}}"#,
        ])
        XCTAssertEqual(CliSessions.scan(root: root).first?.title, "블록으로 온 물음")
    }

    /// 훅이 붙인 덩어리를 제목에 올리면 모든 세션 제목이 같아진다.
    func testStripsSystemReminder() throws {
        try write("ddd", project: "-p", lines: [
            #"{"type":"user","cwd":"/tmp/x","message":{"role":"user","content":"진짜 물음\n<system-reminder>이건 제목이 아니다</system-reminder>"}}"#,
        ])
        XCTAssertEqual(CliSessions.scan(root: root).first?.title, "진짜 물음")
    }

    func testUntitledWhenNothingReadable() throws {
        try write("eee", project: "-p", lines: [#"{"type":"mode","mode":"normal"}"#])
        let session = try XCTUnwrap(CliSessions.scan(root: root).first)
        XCTAssertEqual(session.title, CliSessions.untitled)
        XCTAssertEqual(session.cwd, "")
    }

    func testLongTitleIsCut() throws {
        let long = String(repeating: "가", count: 200)
        try write("fff", project: "-p", lines: [
            #"{"type":"user","cwd":"/tmp/x","message":{"role":"user","content":"\#(long)"}}"#,
        ])
        let title = try XCTUnwrap(CliSessions.scan(root: root).first?.title)
        XCTAssertTrue(title.hasSuffix("..."), title)
        XCTAssertEqual(title.count, 63)
    }

    // MARK: 차례와 개수

    func testNewestFirstAcrossProjects() throws {
        let now = Date()
        try write("old", project: "-a", lines: [#"{"type":"custom-title","customTitle":"옛것"}"#],
                  at: now.addingTimeInterval(-3600))
        try write("new", project: "-b", lines: [#"{"type":"custom-title","customTitle":"새것"}"#],
                  at: now)
        XCTAssertEqual(CliSessions.scan(root: root).map(\.title), ["새것", "옛것"])
    }

    func testLimitCutsTheTail() throws {
        let now = Date()
        for i in 0..<5 {
            try write("s\(i)", project: "-a",
                      lines: [#"{"type":"custom-title","customTitle":"세션 \#(i)"}"#],
                      at: now.addingTimeInterval(TimeInterval(-i * 60)))
        }
        XCTAssertEqual(CliSessions.scan(root: root, limit: 2).map(\.title), ["세션 0", "세션 1"])
    }

    /// jsonl 이 아닌 것은 세션이 아니다. 같은 폴더에 도구가 남긴 것이 있다.
    func testIgnoresNonTranscripts() throws {
        try write("ggg", project: "-a", lines: [#"{"type":"custom-title","customTitle":"세션"}"#])
        let dir = root.appendingPathComponent("-a")
        try "메모".write(to: dir.appendingPathComponent("note.txt"),
                        atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("tool-results"), withIntermediateDirectories: true)
        XCTAssertEqual(CliSessions.scan(root: root).count, 1)
    }

    func testMissingRootIsEmpty() {
        let gone = root.appendingPathComponent("없는곳")
        XCTAssertTrue(CliSessions.scan(root: gone).isEmpty)
    }

    // MARK: 큰 파일

    /// 수십 MB 기록을 통째로 읽지 않는다. 앞부분만 보고 답한다.
    func testReadsOnlyTheHeadOfHugeTranscripts() throws {
        let filler = String(repeating: "x", count: 4096)
        var lines = [#"{"type":"custom-title","customTitle":"큰 세션"}"#,
                     #"{"type":"user","cwd":"/tmp/big","message":{"role":"user","content":"물음"}}"#]
        for _ in 0..<400 { lines.append(#"{"type":"assistant","text":"\#(filler)"}"#) }
        try write("big", project: "-a", lines: lines)

        let session = try XCTUnwrap(CliSessions.scan(root: root).first)
        XCTAssertEqual(session.title, "큰 세션")
        XCTAssertEqual(session.cwd, "/tmp/big")
        XCTAssertGreaterThan(CliSessions.head(root.appendingPathComponent("-a/big.jsonl")).count, 1)
        // 앞 64KB 만 읽으므로 뒤쪽 줄은 안 들어온다
        XCTAssertLessThan(CliSessions.head(root.appendingPathComponent("-a/big.jsonl")).count, 402)
    }

    // MARK: 표시

    func testFolderShortensHome() {
        let home = URL(fileURLWithPath: "/Users/me")
        let session = CliSession(id: "a", title: "t", cwd: "/Users/me/repos/clf",
                                 modifiedAt: Date())
        XCTAssertEqual(session.folder(home: home), "~/repos/clf")
    }

    func testFolderKeepsPathsOutsideHome() {
        let home = URL(fileURLWithPath: "/Users/me")
        let session = CliSession(id: "a", title: "t", cwd: "/opt/work", modifiedAt: Date())
        XCTAssertEqual(session.folder(home: home), "/opt/work")
    }

    /// 홈과 이름이 겹치는 형제 디렉토리를 홈 아래로 착각하면 안 된다.
    func testFolderDoesNotMatchSiblingPrefix() {
        let home = URL(fileURLWithPath: "/Users/me")
        let session = CliSession(id: "a", title: "t", cwd: "/Users/meta/x", modifiedAt: Date())
        XCTAssertEqual(session.folder(home: home), "/Users/meta/x")
    }
}
