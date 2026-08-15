import XCTest
@testable import ClfDesktop

/// CLI 로그인 계정 확인. 답을 읽는 쪽과 한 줄로 만드는 쪽을 따로 본다.
final class CliAuthTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func script(_ body: String) throws -> URL {
        let url = dir.appendingPathComponent("fake-claude-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                             ofItemAtPath: url.path)
        return url
    }

    // MARK: 답 읽기

    func testReadsLoggedInAccount() {
        let json = """
        {"loggedIn":true,"authMethod":"claude.ai","email":"me@example.com",
         "orgId":"2a06","orgName":"NAVER_TEAM_52","subscriptionType":"team"}
        """
        XCTAssertEqual(CliAuthReader.parse(json),
                       .loggedIn(orgID: "2a06", orgName: "NAVER_TEAM_52"))
    }

    func testReadsLoggedOut() {
        XCTAssertEqual(CliAuthReader.parse(#"{"loggedIn":false}"#), .loggedOut)
    }

    /// 앞뒤에 다른 줄이 섞여도 JSON 만 본다. 업데이트 안내 같은 것이 붙는다.
    func testIgnoresSurroundingNoise() {
        let text = "Checking...\n{\"loggedIn\":true,\"orgId\":\"a\",\"orgName\":\"팀\"}\ndone\n"
        XCTAssertEqual(CliAuthReader.parse(text), .loggedIn(orgID: "a", orgName: "팀"))
    }

    /// 조직이 없으면 대조할 수 없다. 모르는 것을 아는 척하지 않는다.
    func testLoggedInWithoutOrgIsUnreadable() {
        guard case .unreadable = CliAuthReader.parse(#"{"loggedIn":true}"#) else {
            return XCTFail("조직을 모르면 확인 못 한 것이다")
        }
    }

    /// 조직 이름이 없으면 이메일로, 그것도 없으면 uuid 로 부른다.
    func testFallsBackToEmailForName() {
        XCTAssertEqual(CliAuthReader.parse(#"{"loggedIn":true,"orgId":"a","email":"me@x.com"}"#),
                       .loggedIn(orgID: "a", orgName: "me@x.com"))
    }

    func testGarbageIsUnreadable() {
        guard case .unreadable = CliAuthReader.parse("command not found") else {
            return XCTFail("JSON 이 아니면 확인 못 한 것이다")
        }
    }

    // MARK: 실행

    func testAsksTheCliForItsStatus() async throws {
        let cli = try script(#"echo "$1 $2 $3"; echo '{"loggedIn":true,"orgId":"a","orgName":"팀"}'"#)
        let status = await CliAuthReader(executable: cli).check()
        XCTAssertEqual(status, .loggedIn(orgID: "a", orgName: "팀"))
    }

    func testNonZeroExitIsUnreadable() async throws {
        let cli = try script("exit 4")
        guard case .unreadable(let why) = await CliAuthReader(executable: cli).check() else {
            return XCTFail("실패는 확인 못 한 것이다")
        }
        XCTAssertTrue(why.contains("4"), why)
    }

    func testMissingExecutableIsUnreadable() async {
        let gone = dir.appendingPathComponent("없는것")
        guard case .unreadable = await CliAuthReader(executable: gone).check() else {
            return XCTFail("못 띄우면 확인 못 한 것이다")
        }
    }

    // MARK: 한 줄

    /// 같은 계정이어도 말한다. 조용하면 확인을 한 것인지 못 한 것인지 모른다.
    func testMatchingAccountIsStillReported() {
        let line = CliAuthStatus.loggedIn(orgID: "a", orgName: "팀A")
            .line(watching: "a", named: "팀A")
        XCTAssertEqual(line.accent, .good)
        XCTAssertTrue(line.text.contains("같습니다"), line.text)
    }

    /// 돌기는 도는데 남의 한도를 쓴다. 실패가 아니라서 알아채기 어렵다.
    func testMismatchedAccountIsFlagged() {
        let line = CliAuthStatus.loggedIn(orgID: "a", orgName: "팀A")
            .line(watching: "b", named: "팀B")
        XCTAssertEqual(line.accent, .bad)
        XCTAssertTrue(line.text.contains("팀A"), line.text)
        XCTAssertTrue(line.text.contains("팀B"), line.text)
    }

    /// 지켜볼 계정을 아직 안 골랐으면 대조할 것이 없다. 로그인 사실만 적는다.
    func testNoWatchedAccountJustReportsLogin() {
        let line = CliAuthStatus.loggedIn(orgID: "a", orgName: "팀A").line(watching: "", named: nil)
        XCTAssertEqual(line.accent, .good)
        XCTAssertFalse(line.text.contains("같습니다"), line.text)
    }

    /// 이름을 모르면 uuid 로라도 어느 쪽이 다른지 말한다.
    func testMismatchWithoutNameUsesUUID() {
        let line = CliAuthStatus.loggedIn(orgID: "a", orgName: "팀A")
            .line(watching: "bbb", named: nil)
        XCTAssertTrue(line.text.contains("bbb"), line.text)
    }

    func testLoggedOutTellsWhatToRun() {
        let line = CliAuthStatus.loggedOut.line(watching: "a", named: "팀")
        XCTAssertEqual(line.accent, .bad)
        XCTAssertTrue(line.text.contains("claude auth login"), line.text)
    }

    /// 확인 중은 색을 안 쓴다. 아직 아무 소식도 아니다.
    func testCheckingIsQuiet() {
        XCTAssertEqual(CliAuthStatus.checking.line(watching: "a", named: "팀").accent, .none)
    }

    func testUnreadableKeepsTheReason() {
        let line = CliAuthStatus.unreadable("응답이 없습니다").line(watching: "a", named: "팀")
        XCTAssertEqual(line.accent, .wait)
        XCTAssertTrue(line.text.contains("응답이 없습니다"), line.text)
    }
}
