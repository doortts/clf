import XCTest
@testable import ClfDesktop

/// 실행과 결과 읽기. 진짜 CLI 대신 흉내 낸 스크립트를 쓴다.
final class ResumeRunnerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resume-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func script(_ body: String, executable: Bool = true) throws -> URL {
        let url = dir.appendingPathComponent("fake-claude-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                 ofItemAtPath: url.path)
        }
        return url
    }

    private func plan(cwd: String = "") -> AutoResumePlan {
        AutoResumePlan(orgUUID: "u", sessionID: "sid", cwd: cwd, title: "제목")
    }

    // MARK: 찾기

    func testFindsFirstExecutable() throws {
        let missing = dir.appendingPathComponent("없음").path
        let real = try script("exit 0")
        XCTAssertEqual(ClaudeCLI.find([missing, real.path]), real)
    }

    func testSkipsNonExecutableFile() throws {
        let plain = try script("exit 0", executable: false)
        XCTAssertNil(ClaudeCLI.find([plain.path]))
    }

    func testCandidatesLookUnderHome() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(ClaudeCLI.candidates(home: home).first, "/Users/me/.local/bin/claude")
    }

    // MARK: 실행

    func testSuccessHasNoDetail() async throws {
        let cli = try script("exit 0")
        let outcome = try await ResumeRunner(executable: cli).run(plan())
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertNil(outcome.detail)
    }

    /// 실패는 exit code 와 stderr 첫 줄을 그대로 전한다.
    func testFailureCarriesExitCodeAndFirstStderrLine() async throws {
        let cli = try script("""
        echo "No conversation found with session ID: sid" >&2
        echo "뒷줄은 안 쓴다" >&2
        exit 1
        """)
        let outcome = try await ResumeRunner(executable: cli).run(plan())
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertEqual(outcome.detail, "No conversation found with session ID: sid")
    }

    /// `--resume <ID> -p <프롬프트>` 를 그 차례로 넘긴다.
    func testPassesResumeArguments() async throws {
        let cli = try script(#"echo "$1|$2|$3|$4" >&2; exit 7"#)
        var wanted = plan()
        wanted.prompt = "이어서 진행해줘"
        let outcome = try await ResumeRunner(executable: cli).run(wanted)
        XCTAssertEqual(outcome.detail, "--resume|sid|-p|이어서 진행해줘")
        XCTAssertEqual(outcome.exitCode, 7)
    }

    /// 세션은 자기 작업 디렉토리에서 돌아야 CLI 가 찾는다.
    func testRunsInTheSessionDirectory() async throws {
        let cli = try script("pwd >&2; exit 1")
        let work = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let outcome = try await ResumeRunner(executable: cli).run(plan(cwd: work.path))
        // 임시 디렉토리는 심볼릭 링크를 타서 경로 문자열이 다를 수 있다
        XCTAssertEqual(URL(fileURLWithPath: outcome.detail ?? "").resolvingSymlinksInPath(),
                       work.resolvingSymlinksInPath())
    }

    /// 파이프 대신 파일로 받는 이유. 64KB 를 넘겨도 서로 붙지 않는다.
    func testSurvivesLargeStderr() async throws {
        let cli = try script("""
        echo "첫 줄이 결론이다" >&2
        i=0
        while [ $i -lt 2000 ]; do
          echo "0123456789012345678901234567890123456789012345678901234567890123" >&2
          i=$((i+1))
        done
        exit 2
        """)
        let outcome = try await ResumeRunner(executable: cli).run(plan())
        XCTAssertEqual(outcome.exitCode, 2)
        XCTAssertEqual(outcome.detail, "첫 줄이 결론이다")
    }

    func testLongLineIsCut() async throws {
        let cli = try script(#"printf '%0.s가' $(seq 1 400) >&2; echo >&2; exit 1"#)
        let detail = try await ResumeRunner(executable: cli).run(plan()).detail
        XCTAssertEqual(detail?.count, 123, detail ?? "")
        XCTAssertTrue(detail?.hasSuffix("...") ?? false)
    }

    func testMissingExecutableThrows() async {
        let gone = dir.appendingPathComponent("없는것")
        do {
            _ = try await ResumeRunner(executable: gone).run(plan())
            XCTFail("없는 실행 파일은 던져야 한다")
        } catch {}
    }
}
