import XCTest
@testable import ClflDesktop

/// 세션을 다른 계정으로 옮긴다.
///
/// 트랜스크립트는 손대지 않는다. 420바이트짜리 레코드 파일 하나를 계정
/// 폴더 사이로 옮기는 것이 전부다. 옮기면 한 계정만 그 대화를 가리키므로
/// 두 창이 같은 파일을 쓰는 일도 없다. docs/design/13-multi-instance.md
final class HandoffPlanTests: XCTestCase {

    /// 대상에 같은 이름이 있으면 덮으면 안 된다. 저쪽이 먼저 쓰던 것이다.
    func test_detectsCollision() {
        XCTAssertTrue(SessionHandoff.collides("local_a.json", in: ["local_a.json"]))
        XCTAssertFalse(SessionHandoff.collides("local_a.json", in: ["local_b.json"]))
        XCTAssertFalse(SessionHandoff.collides("local_a.json", in: []))
    }

    /// 같은 계정으로는 옮길 것이 없다.
    func test_sameAccountIsNotAMove() {
        XCTAssertFalse(SessionHandoff.canMove(from: "acct", to: "acct"))
        XCTAssertTrue(SessionHandoff.canMove(from: "a", to: "b"))
    }
}

/// 목록에 뜨는 제목을 찾는다.
final class TranscriptTitleTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ lines: [String]) throws -> URL {
        let url = dir.appendingPathComponent("t.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_readsAiTitle() throws {
        let f = try write([#"{"type":"ai-title","aiTitle":"기본 산술 계산"}"#])
        XCTAssertEqual(TranscriptTitle.of(f), "기본 산술 계산")
    }

    /// 사용자가 이름을 바꿨으면 그쪽이 이긴다. 앱도 그 순서로 본다.
    func test_customTitleWins() throws {
        let f = try write([#"{"type":"ai-title","aiTitle":"자동 제목"}"#,
                           #"{"type":"custom-title","customTitle":"내가 지은 이름"}"#])
        XCTAssertEqual(TranscriptTitle.of(f), "내가 지은 이름")
    }

    /// 나중 것이 이긴다. 제목은 여러 번 바뀔 수 있다.
    func test_lastOneWins() throws {
        let f = try write([#"{"type":"ai-title","aiTitle":"처음"}"#,
                           #"{"type":"ai-title","aiTitle":"나중"}"#])
        XCTAssertEqual(TranscriptTitle.of(f), "나중")
    }

    /// 제목이 없으면 빈 문자열. 지어내지 않는다.
    func test_noTitle() throws {
        XCTAssertEqual(TranscriptTitle.of(try write([#"{"type":"mode"}"#])), "")
    }

    func test_missingFile() {
        XCTAssertEqual(TranscriptTitle.of(dir.appendingPathComponent("없다.jsonl")), "")
    }

    /// **파일을 통째로 안 읽는다.** 트랜스크립트는 73MB 도 된다.
    /// 제목은 앞이나 뒤에 있으므로 양끝만 본다.
    func test_findsTitleInATailOfALargeFile() throws {
        let url = dir.appendingPathComponent("big.jsonl")
        var body = ""
        for i in 0..<20_000 { body += #"{"type":"user","n":\#(i)}"# + "\n" }
        body += #"{"type":"ai-title","aiTitle":"끝에 있는 제목"}"# + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, TranscriptTitle.edgeBytes)
        XCTAssertEqual(TranscriptTitle.of(url), "끝에 있는 제목")
    }
}

/// 실제 파일로 옮겨본다.
final class HandoffMoveTests: XCTestCase {
    private var root: URL!
    private var a: SessionStore!
    private var b: SessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString)")
        a = SessionStore(dataDirectory: root, person: "p", account: "A")
        b = SessionStore(dataDirectory: root, person: "p", account: "B")
        try FileManager.default.createDirectory(at: a.root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func put(_ store: SessionStore, _ name: String, cli: String = "c1") throws {
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try Data(#"{"sessionId":"s","cliSessionId":"\#(cli)"}"#.utf8)
            .write(to: store.root.appendingPathComponent(name))
    }

    func test_movesTheRecord() throws {
        try put(a, "local_x.json")
        try SessionHandoff.move("local_x.json", from: a, to: b)
        XCTAssertEqual(a.fileNames(), [])
        XCTAssertEqual(b.fileNames(), ["local_x.json"])
    }

    /// 대상 폴더가 없어도 만든다. 그 계정 창을 아직 안 띄웠을 수 있다.
    func test_createsTargetFolder() throws {
        try put(a, "local_x.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.root.path))
        try SessionHandoff.move("local_x.json", from: a, to: b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.root.path))
    }

    /// 덮지 않는다. 저쪽이 먼저 쓰던 것을 잃으면 안 된다.
    func test_refusesToOverwrite() throws {
        try put(a, "local_x.json")
        try put(b, "local_x.json")
        XCTAssertThrowsError(try SessionHandoff.move("local_x.json", from: a, to: b))
        // 실패했으면 원본이 그대로 있어야 한다
        XCTAssertEqual(a.fileNames(), ["local_x.json"])
    }

    func test_missingSource() {
        XCTAssertThrowsError(try SessionHandoff.move("local_없다.json", from: a, to: b))
    }
}

/// 한 계정의 레코드는 자리가 여럿이다. 기본 데이터 디렉토리에 있고,
/// 그 계정으로 띄운 별도 창이 있으면 거기에도 있다. 옮기면 전부 옮겨야
/// 한 창에만 남는 일이 없다.
final class HandoffSiteTests: XCTestCase {
    private var home: URL!
    private var primary: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sites-\(UUID().uuidString)")
        primary = home.appendingPathComponent("Primary")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func store(_ dir: URL, _ account: String) -> SessionStore {
        SessionStore(dataDirectory: dir, person: "p", account: account)
    }
    private func put(_ store: SessionStore, _ name: String) throws {
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try Data(#"{"sessionId":"s","cliSessionId":"c1"}"#.utf8)
            .write(to: store.root.appendingPathComponent(name))
    }

    func test_primaryOnlyWhenNoWindow() {
        let s = SessionHandoff.stores(account: "u1", name: "A",
                                      primary: primary, person: "p", home: home)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].root, store(primary, "u1").root)
    }

    func test_includesTheWindowDirectory() throws {
        let alt = home.appendingPathComponent(AltInstance.prefix + "A")
        try FileManager.default.createDirectory(at: alt, withIntermediateDirectories: true)
        let s = SessionHandoff.stores(account: "u1", name: "A",
                                      primary: primary, person: "p", home: home)
        XCTAssertEqual(s.map(\.root), [store(primary, "u1").root, store(alt, "u1").root])
    }

    /// 자리마다 다 옮긴다. 한 군데만 옮기면 남은 창이 계속 보여준다.
    func test_movesEveryCopy() throws {
        let altA = home.appendingPathComponent(AltInstance.prefix + "A")
        try FileManager.default.createDirectory(at: altA, withIntermediateDirectories: true)
        let from = SessionHandoff.stores(account: "u1", name: "A",
                                         primary: primary, person: "p", home: home)
        let to = SessionHandoff.stores(account: "u2", name: "B",
                                       primary: primary, person: "p", home: home)
        for s in from { try put(s, "local_x.json") }

        try SessionHandoff.move("local_x.json", from: from, to: to)

        XCTAssertEqual(from.flatMap { $0.fileNames() }, [])
        XCTAssertEqual(to.flatMap { $0.fileNames() }, ["local_x.json"])
    }

    /// 어느 한 자리에만 있어도 옮긴다. 창을 늦게 띄웠으면 그럴 수 있다.
    func test_movesWhenOnlyOneSiteHasIt() throws {
        let altA = home.appendingPathComponent(AltInstance.prefix + "A")
        try FileManager.default.createDirectory(at: altA, withIntermediateDirectories: true)
        let from = SessionHandoff.stores(account: "u1", name: "A",
                                         primary: primary, person: "p", home: home)
        try put(from[1], "local_x.json")

        try SessionHandoff.move("local_x.json", from: from,
                                to: SessionHandoff.stores(account: "u2", name: "B",
                                                          primary: primary, person: "p", home: home))
        XCTAssertEqual(from.flatMap { $0.fileNames() }, [])
        XCTAssertEqual(store(primary, "u2").fileNames(), ["local_x.json"])
    }

    /// 대상 한 자리에라도 이미 있으면 손대지 않는다.
    func test_collisionLeavesEverythingAlone() throws {
        let from = SessionHandoff.stores(account: "u1", name: "A",
                                         primary: primary, person: "p", home: home)
        let to = SessionHandoff.stores(account: "u2", name: "B",
                                       primary: primary, person: "p", home: home)
        try put(from[0], "local_x.json")
        try put(to[0], "local_x.json")
        XCTAssertThrowsError(try SessionHandoff.move("local_x.json", from: from, to: to))
        XCTAssertEqual(from[0].fileNames(), ["local_x.json"])
    }
}

/// 옮기기 전에 무슨 말을 해줘야 하나.
///
/// 예전 문구는 "옮기면 목록에서 빠진다" 였는데 거짓이었다. 목록 갱신이
/// 더하기만 해서 재시작 전까지 안 빠진다. docs/design/13-multi-instance.md 12절
final class HandoffPlanTextTests: XCTestCase {
    private func plan(_ from: InstanceSlot, _ to: InstanceSlot) -> HandoffPlan {
        .before(source: ("A", from), target: ("B", to))
    }

    func test_saysWhereItGoesAndWhatIsUntouched() {
        let m = plan(.none, .none).moves
        XCTAssertTrue(m.contains("B"))
        XCTAssertTrue(m.contains("대화 내용"))
    }

    /// 기본 창에서 보내면 재시작을 권한다. 이것이 이 안내의 요점이다.
    func test_primarySourceRecommendsARestart() {
        let note = plan(.primary, .none).sourceNote
        XCTAssertNotNil(note)
        XCTAssertTrue(note!.contains("재시작"))
        XCTAssertTrue(note!.contains("남아"))
    }

    /// 왜 재시작해야 하는지도 말한다. 이유 없는 권고는 안 지켜진다.
    func test_saysWhyTheRestartMatters() {
        XCTAssertTrue(plan(.primary, .none).sourceNote!.contains("누르면"))
    }

    /// 별도 창은 우리가 다시 띄운다. 사용자가 할 일이 없다.
    func test_runningSourceIsHandledByUs() {
        let note = plan(.running, .none).sourceNote
        XCTAssertTrue(note!.contains("다시 띄워"))
        XCTAssertFalse(note!.contains("재시작"))
    }

    /// 창이 없으면 할 말이 없다. 빈 줄을 만들지 않는다.
    func test_noWindowSaysNothing() {
        XCTAssertNil(plan(.none, .none).sourceNote)
        XCTAssertNil(plan(.none, .none).targetNote)
    }

    /// 받는 쪽이 기본 창이면 나타나게 하려고 재시작이 필요하다. 방향만 다르다.
    func test_primaryTargetAlsoNeedsARestart() {
        XCTAssertTrue(plan(.none, .primary).targetNote!.contains("재시작"))
    }

    func test_linesDropTheEmptyOnes() {
        XCTAssertEqual(plan(.none, .none).lines.count, 1)
        XCTAssertEqual(plan(.primary, .none).lines.count, 2)
        XCTAssertEqual(plan(.running, .primary).lines.count, 3)
    }
}

/// 옮긴 뒤 무슨 말을 해줘야 하나. 앱은 세션 목록을 메모리에 들고 있어서
/// 파일만 바꿔서는 화면이 안 바뀐다.
final class HandoffAdviceTests: XCTestCase {
    private func advice(_ from: InstanceSlot, _ to: InstanceSlot) -> HandoffAdvice {
        .after(moved: 1, source: ("A", from), target: ("B", to))
    }

    func test_primarySourceAsksForARestart() {
        let a = advice(.primary, .none)
        XCTAssertTrue(a.needsPrimaryRestart)
        XCTAssertEqual(a.relaunch, [])
    }

    func test_primaryTargetAlsoAsksForARestart() {
        XCTAssertTrue(advice(.none, .primary).needsPrimaryRestart)
    }

    /// 별도 창은 우리가 띄운 것이라 다시 띄울 수 있다. 단추로 보여준다.
    func test_offersToRelaunchWindows() {
        XCTAssertEqual(advice(.running, .running).relaunch, ["A", "B"])
        XCTAssertFalse(advice(.running, .running).needsPrimaryRestart)
    }

    /// 창이 없는 쪽은 할 일이 없다. 다음에 띄우면 그냥 보인다.
    func test_noWindowNeedsNothing() {
        let a = advice(.none, .none)
        XCTAssertFalse(a.needsPrimaryRestart)
        XCTAssertEqual(a.relaunch, [])
        XCTAssertTrue(a.text.contains("다음에"))
    }

    func test_countsWhatMoved() {
        XCTAssertTrue(HandoffAdvice.after(moved: 3, source: ("A", .none), target: ("B", .none))
            .text.hasPrefix("3개"))
    }
}

/// 넘기기 전에 알아야 할 것 둘. 대화가 없거나 작업 폴더가 없으면 옮겨 봐야
/// 쓸 수 없다.
///
/// **막지는 않는다.** 넘기기는 사용자가 명시적으로 하는 일이라 판단은 사용자
/// 몫이다. 우리는 판단할 재료만 준다. docs/design/13-multi-instance.md
final class SessionWarningTests: XCTestCase {
    private var root: URL!
    private var projects: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("warn-\(UUID().uuidString)")
        projects = root.appendingPathComponent("projects")
        store = SessionStore(dataDirectory: root, person: "p", account: "A")
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func put(cwd: String, cli: String = "c1") throws {
        try Data(#"{"sessionId":"s","cliSessionId":"\#(cli)","cwd":"\#(cwd)"}"#.utf8)
            .write(to: store.root.appendingPathComponent("local_x.json"))
    }
    private func putTranscript(_ cli: String = "c1") throws {
        let dir = projects.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("\(cli).jsonl"))
    }
    private func only(_ exists: @escaping (String) -> Bool) -> SessionSummary {
        store.summaries(projects: projects, folderExists: exists)[0]
    }

    func test_nothingToSayWhenBothAreThere() throws {
        try put(cwd: "/repo")
        try putTranscript()
        let s = only { _ in true }
        XCTAssertNil(s.warning)
        XCTAssertEqual(s.folder, "repo")
    }

    /// worktree 를 지우면 폴더가 없어진다. 옮겨도 그 자리에서 일할 수 없다.
    func test_marksAMissingFolder() throws {
        try put(cwd: "/repo/wt")
        try putTranscript()
        XCTAssertEqual(only { _ in false }.warning, SessionSummary.noFolder)
    }

    /// 확인은 레코드에 적힌 경로로 한다. 짐작하지 않는다.
    func test_asksAboutTheRecordedPath() throws {
        try put(cwd: "/repo/wt")
        try putTranscript()
        var asked: [String] = []
        _ = only { asked.append($0); return true }
        XCTAssertEqual(asked, ["/repo/wt"])
    }

    /// 대화가 아예 없는 쪽이 더 큰 문제다. 둘 다면 그쪽을 말한다.
    func test_missingTranscriptWins() throws {
        try put(cwd: "/repo/wt")
        XCTAssertEqual(only { _ in false }.warning, SessionSummary.noTranscript)
    }

    /// 경로를 모르면 없다고 말하지 않는다. 지어낸 경고는 진짜 경고를 묻는다.
    func test_unknownPathIsNotAWarning() throws {
        try put(cwd: "")
        try putTranscript()
        XCTAssertNil(only { _ in false }.warning)
    }

    /// 기본값은 실제 파일 시스템을 본다. 호출부가 아무것도 안 넘겨도 동작해야 한다.
    func test_defaultLooksAtTheRealFileSystem() throws {
        try put(cwd: root.path)
        try putTranscript()
        XCTAssertNil(store.summaries(projects: projects)[0].warning)
    }
}

/// 마지막으로 쓴 때를 사람이 읽는 말로. `until` 의 반대 방향이다.
final class SinceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func ago(_ seconds: TimeInterval) -> String {
        BarText.since(now.addingTimeInterval(-seconds), from: now)
    }

    func test_justNow() { XCTAssertEqual(ago(30), "방금") }
    func test_minutes() { XCTAssertEqual(ago(600), "10분 전") }
    func test_hours() { XCTAssertEqual(ago(7200), "2시간 전") }
    func test_yesterday() { XCTAssertEqual(ago(90_000), "어제") }
    func test_days() { XCTAssertEqual(ago(3 * 86_400), "3일 전") }
    /// 시계가 어긋나 미래로 찍힐 수 있다. "-2분 전" 을 보여주면 고장으로 보인다
    func test_futureReadsAsNow() { XCTAssertEqual(ago(-600), "방금") }
    func test_noDate() { XCTAssertEqual(BarText.since(nil, from: now), "") }
}
