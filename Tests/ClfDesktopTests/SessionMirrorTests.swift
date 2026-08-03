import XCTest
@testable import ClfDesktop

/// 세션 레코드를 계정 사이로 옮긴다.
///
/// 레코드는 트랜스크립트를 가리키는 포인터일 뿐이고 트랜스크립트는 공유된다.
/// 그래서 같은 대화를 계정마다 따로 가리킬 수 있다.
/// docs/design/13-multi-instance.md 4절
final class MirrorPlanTests: XCTestCase {

    private func rec(_ file: String, _ id: String?) -> SessionMirror.Record {
        .init(fileName: file, transcriptID: id)
    }

    func test_copiesWhatTheTargetLacks() {
        let plan = SessionMirror.plan(source: [rec("local_a.json", "a"), rec("local_b.json", "b")],
                                      target: ["local_a.json"],
                                      hasTranscript: { _ in true })
        XCTAssertEqual(plan, ["local_b.json"])
    }

    /// **파일 이름의 uuid 와 트랜스크립트 id 는 다를 수 있다.** 앱이 직접
    /// 만든 세션은 둘이 따로다. 이름으로 짐작하면 멀쩡한 세션을 빠뜨린다.
    func test_transcriptIdIsNotTheFileName() {
        let plan = SessionMirror.plan(
            source: [rec("local_071c8461.json", "766182af")], target: [],
            hasTranscript: { $0 == "766182af" })
        XCTAssertEqual(plan, ["local_071c8461.json"])
    }

    /// cliSessionId 가 없는 레코드는 옮길 수 없다.
    func test_recordWithoutATranscriptId() {
        XCTAssertTrue(SessionMirror.plan(source: [rec("local_a.json", nil)], target: [],
                                         hasTranscript: { _ in true }).isEmpty)
    }

    /// 이미 있는 것은 안 건드린다. 저쪽에서 고친 것을 덮으면 안 된다.
    func test_neverOverwrites() {
        XCTAssertTrue(SessionMirror.plan(source: [rec("local_a.json", "a")],
                                         target: ["local_a.json"],
                                         hasTranscript: { _ in true }).isEmpty)
    }

    /// 트랜스크립트가 없으면 옮겨도 빈 세션이 뜬다. 그건 고장으로 보인다.
    func test_skipsRecordsWithoutATranscript() {
        let plan = SessionMirror.plan(source: [rec("local_a.json", "a"), rec("local_b.json", "b")],
                                      target: [], hasTranscript: { $0 == "a" })
        XCTAssertEqual(plan, ["local_a.json"])
    }

    /// 우리 형식이 아닌 파일은 무시한다.
    func test_ignoresForeignFiles() {
        let plan = SessionMirror.plan(
            source: [rec("local_a.json", "a"), rec("notes.txt", "n"), rec("draft_x.json", "d")],
            target: [], hasTranscript: { _ in true })
        XCTAssertEqual(plan, ["local_a.json"])
    }

    func test_recognizesOurFiles() {
        XCTAssertTrue(SessionMirror.isOurs("local_a.json"))
        XCTAssertFalse(SessionMirror.isOurs("notes.txt"))
        XCTAssertFalse(SessionMirror.isOurs("local_.json"))
    }

    func test_emptySource() {
        XCTAssertTrue(SessionMirror.plan(source: [], target: ["local_a.json"],
                                         hasTranscript: { _ in true }).isEmpty)
    }

    /// 순서가 일정해야 한다. 로그가 매번 달라지면 못 읽는다.
    func test_stableOrder() {
        let files = ["local_c.json", "local_a.json", "local_b.json"].map { rec($0, $0) }
        XCTAssertEqual(SessionMirror.plan(source: files, target: [], hasTranscript: { _ in true }),
                       ["local_a.json", "local_b.json", "local_c.json"])
    }
}
