import XCTest
@testable import ClflDesktop

/// 트랜스크립트를 다른 계정으로 넘기려고 복제한다.
///
/// 앱의 Fork 와 같은 방식이다. 줄을 그대로 복사하고 uuid 를 안 고친다.
/// 다만 짝 없는 `tool_use` 로 끝난 파일은 복사해도 안 열리므로 그것만 떼어낸다.
/// docs/design/13-multi-instance.md
final class TranscriptForkTests: XCTestCase {

    private func line(_ json: String) -> Data { Data(json.utf8) }
    private func assistantUsing(_ id: String) -> Data {
        line(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"\#(id)"}]}}"#)
    }
    private func userResult(_ id: String) -> Data {
        line(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)"}]}}"#)
    }
    private let endTurn = Data(
        #"{"type":"assistant","message":{"content":[{"type":"text"}],"stop_reason":"end_turn"}}"#.utf8)
    private let userText = Data(
        #"{"type":"user","message":{"content":[{"type":"text"}]}}"#.utf8)

    /// 대화가 닫혀 있으면 한 줄도 안 뗀다.
    func test_keepsEverythingWhenClosed() {
        let lines = [userText, assistantUsing("t1"), userResult("t1"), endTurn]
        XCTAssertEqual(TranscriptFork.keepCount(lines), 4)
    }

    /// **한도에 걸린 모습이다.** 도구 결과까지 받고 다음 요청이 실패했다.
    /// 짝이 맞으므로 그대로 넘어간다. 이게 이 기능의 주 용도다.
    func test_keepsEverythingWhenEndingOnToolResult() {
        let lines = [assistantUsing("t1"), userResult("t1")]
        XCTAssertEqual(TranscriptFork.keepCount(lines), 2)
    }

    /// 답을 기다리는 상태도 유효하다. 새 계정에서 그 답부터 받는다.
    func test_keepsEverythingWhenAwaitingAnAnswer() {
        XCTAssertEqual(TranscriptFork.keepCount([endTurn, userText]), 2)
    }

    /// 짝 없는 도구 호출로 끝나면 그것만 뗀다. 안 그러면 복사본이 안 열린다.
    func test_dropsUnpairedToolUse() {
        let lines = [userResult("t0"), assistantUsing("t1")]
        XCTAssertEqual(TranscriptFork.keepCount(lines), 1)
    }

    /// 뒤에 딸린 메타 줄까지 함께 뗀다. 남겨 두면 없는 항목을 가리킨다.
    func test_dropsTrailingMetadataToo() {
        let lines = [endTurn, assistantUsing("t1"), line(#"{"type":"last-prompt"}"#)]
        XCTAssertEqual(TranscriptFork.keepCount(lines), 1)
    }

    /// 도구를 여럿 부르고 하나만 돌아왔으면 아직 짝이 안 맞는다.
    func test_partialResultsAreStillUnpaired() {
        let two = line(#"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"a"},{"type":"tool_use","id":"b"}]}}
        """#)
        XCTAssertEqual(TranscriptFork.keepCount([endTurn, two, userResult("a")]), 1)
        XCTAssertEqual(TranscriptFork.keepCount([endTurn, two, userResult("a"), userResult("b")]), 4)
    }

    /// 쓰다 만 줄은 버린다. append 중간에 읽으면 나올 수 있다.
    func test_dropsUnparsableTail() {
        XCTAssertEqual(TranscriptFork.keepCount([endTurn, line(#"{"type":"assis"#)]), 1)
    }

    func test_emptyInput() {
        XCTAssertEqual(TranscriptFork.keepCount([]), 0)
    }

    /// 메타 줄만 있고 메시지가 없으면 넘길 것이 없다.
    func test_metadataOnly() {
        XCTAssertEqual(TranscriptFork.keepCount([line(#"{"type":"mode"}"#)]), 1)
    }
}

/// 복사본에 붙일 제목 줄.
final class ForkTitleTests: XCTestCase {

    func test_marksTheCopy() throws {
        let data = try XCTUnwrap(TranscriptFork.titleLine(sessionID: "s1", title: "기본 산술 계산"))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "custom-title")
        XCTAssertEqual(json["sessionId"] as? String, "s1")
        XCTAssertEqual(json["customTitle"] as? String, "[넘김] 기본 산술 계산")
    }

    /// 두 번 넘겨도 표시가 겹치지 않는다.
    func test_doesNotStackTheMarker() throws {
        let data = try XCTUnwrap(
            TranscriptFork.titleLine(sessionID: "s1", title: "[넘김] 기본 산술 계산"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["customTitle"] as? String, "[넘김] 기본 산술 계산")
    }

    /// 제목을 못 찾았으면 표시만 붙인다.
    func test_untitled() throws {
        let data = try XCTUnwrap(TranscriptFork.titleLine(sessionID: "s1", title: ""))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["customTitle"] as? String, "[넘김]")
    }
}

/// 실제 트랜스크립트로 끝까지 돌려본다.
///
/// 원본은 안 건드린다. 임시 디렉토리에 사본을 두고 거기서 복제한다.
final class ForkOnRealTranscriptTests: XCTestCase {
    private var work: URL!
    private var source: URL!

    override func setUpWithError() throws {
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/-Users-cpm4-repos-clfl")
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: real.path))?
            .filter({ $0.hasSuffix(".jsonl") })
            .min(by: { a, b in
                let s = { (n: String) in (try? FileManager.default
                    .attributesOfItem(atPath: real.appendingPathComponent(n).path)[.size]
                    as? Int) ?? 0 }
                return (s(a) ?? 0) < (s(b) ?? 0)
            })
        else { throw XCTSkip("이 기계에 트랜스크립트가 없다") }

        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("fork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        source = work.appendingPathComponent(name)
        try FileManager.default.copyItem(at: real.appendingPathComponent(name), to: source)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    func test_copiesAndMarks() throws {
        let title = TranscriptFork.title(of: source)
        XCTAssertFalse(title.isEmpty, "제목을 못 읽었다")

        let copy = try TranscriptFork.copy(transcript: source, title: title)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path.path))
        XCTAssertEqual(copy.path.lastPathComponent, "\(copy.cliSessionID).jsonl")

        // 복사본의 제목에 표시가 붙는다
        XCTAssertEqual(TranscriptFork.title(of: copy.path), "\(TranscriptFork.marker) \(title)")
    }

    /// 줄이 안 깨진다. 모든 줄이 여전히 JSON 이어야 한다.
    func test_everyLineStaysValid() throws {
        let copy = try TranscriptFork.copy(transcript: source,
                                           title: TranscriptFork.title(of: source))
        let data = try Data(contentsOf: copy.path)
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        XCTAssertGreaterThan(lines.count, 1)
        for line in lines {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line)),
                            "깨진 줄이 있다")
        }
    }

    /// 원본은 그대로다.
    func test_sourceUntouched() throws {
        let before = try Data(contentsOf: source)
        _ = try TranscriptFork.copy(transcript: source, title: "t")
        XCTAssertEqual(try Data(contentsOf: source), before)
    }
}
