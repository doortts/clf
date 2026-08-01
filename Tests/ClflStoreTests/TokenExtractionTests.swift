import XCTest
@testable import ClflStore

/// `claude setup-token` 은 파이프로 넘겨도 ANSI 제어 문자와 화면 다시 그리기를
/// 그대로 뿜는다. 사용자가 grep 파이프라인을 만들 것이 아니라 도구가 뽑아내야 한다.
final class TokenExtractionTests: XCTestCase {

    let token = "sk-ant-oat01-" + String(repeating: "aB3-_x", count: 20)

    func extract(_ text: String) throws -> TokenExtraction {
        try extractToken(from: text)
    }

    // MARK: 깨끗한 입력

    func test_cleanTokenPassesUntouched() throws {
        let result = try extract(token)
        XCTAssertEqual(result.text, token)
        XCTAssertFalse(result.wasCleaned, "손댄 것이 없으면 알릴 것도 없다")
    }

    func test_surroundingWhitespaceIsNotContamination() throws {
        let result = try extract("\n  \(token)  \n")
        XCTAssertEqual(result.text, token)
        XCTAssertFalse(result.wasCleaned)
    }

    // MARK: ANSI 와 화면 다시 그리기

    func test_stripsAnsiColorCodes() throws {
        let result = try extract("\u{1B}[32m\(token)\u{1B}[0m")
        XCTAssertEqual(result.text, token)
        XCTAssertTrue(result.wasCleaned)
    }

    func test_stripsCursorMovementAndClearCodes() throws {
        let result = try extract("\u{1B}[2K\u{1B}[1G토큰: \(token)\u{1B}[?25h")
        XCTAssertEqual(result.text, token)
    }

    func test_stripsOscSequence() throws {
        let result = try extract("\u{1B}]0;제목\u{07}\(token)")
        XCTAssertEqual(result.text, token)
    }

    /// 같은 줄을 여러 번 다시 그린 출력. 같은 토큰이 반복돼도 하나로 본다.
    func test_dedupesRepeatedRedraws() throws {
        let spam = (1...5).map { _ in "\u{1B}[2K\r\(token)" }.joined()
        XCTAssertEqual(try extract(spam).text, token)
    }

    /// 실제로 겪은 것. Powerline 프롬프트 장식이 뒤에 붙었다.
    func test_stripsPromptGlyphs() throws {
        let result = try extract("\(token)\u{E0B2} \u{F080} 4.59")
        XCTAssertEqual(result.text, token)
        XCTAssertTrue(result.wasCleaned)
    }

    func test_pullsTokenOutOfSurroundingProse() throws {
        let text = """
        Success! Use this token:

          \(token)

        Set it as ANTHROPIC_AUTH_TOKEN.
        """
        XCTAssertEqual(try extract(text).text, token)
    }

    // MARK: 거부

    /// 서로 다른 토큰이 둘이면 어느 쪽인지 우리가 정할 수 없다.
    func test_rejectsTwoDifferentTokens() {
        let other = "sk-ant-oat01-" + String(repeating: "zZ9", count: 40)
        assertRejected("\(token)\n\(other)", contains: "2개")
    }

    func test_rejectsWhenNoTokenFound() {
        assertRejected("여기에는 토큰이 없다", contains: "찾지 못했다")
    }

    func test_rejectsEmpty() {
        assertRejected("", contains: "비었다")
    }

    /// 줄바꿈이 토큰 한가운데 들어가면 앞쪽 조각만 뽑힌다. 그걸 저장하면
    /// 401 을 맞고 사용자는 이유를 모른다. 길이로 걸러 미리 말한다.
    func test_rejectsSuspiciouslyShortToken() {
        assertRejected("sk-ant-oat01-abcdefgh", contains: "짧다")
    }

    // MARK: oauth 캡처

    func test_passesOAuthJSONThrough() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1800000000000}}"#
        let result = try extract(json)
        XCTAssertEqual(result.text, json)
        XCTAssertFalse(result.wasCleaned)
    }

    func test_pullsOAuthJSONOutOfAnsiNoise() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1800000000000}}"#
        let result = try extract("\u{1B}[32m\(json)\u{1B}[0m\n")
        XCTAssertEqual(result.text, json)
        XCTAssertTrue(result.wasCleaned)
    }

    /// JSON 안의 공백은 오염이 아니다.
    func test_oauthJSONKeepsInternalSpaces() throws {
        let json = #"{"claudeAiOauth": {"accessToken": "a", "refreshToken": "r", "expiresAt": 1800000000000}}"#
        XCTAssertEqual(try extract(json).text, json)
    }

    /// 필드가 빠진 블록은 캡처가 덜 된 것이다. 저장하면 나중에 못 읽는다.
    /// 깨끗한 입력이어도 검사한다. 오염 여부와 완전성은 다른 문제다.
    func test_rejectsIncompleteOAuthBlock() {
        assertRejected(#"{"claudeAiOauth":{"accessToken":"a"}}"#, contains: "expiresAt")
    }

    func test_rejectsIncompleteOAuthBlockBuriedInNoise() {
        assertRejected("\u{1B}[32m" + #"{"claudeAiOauth":{"accessToken":"a"}}"#,
                       contains: "expiresAt")
    }

    private func assertRejected(_ text: String, contains needle: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        do {
            let result = try extractToken(from: text)
            XCTFail("거부해야 한다. 뽑힌 것: \(result.text)", file: file, line: line)
        } catch {
            XCTAssertTrue("\(error)".contains(needle),
                          "메시지에 \(needle) 이 없다: \(error)", file: file, line: line)
        }
    }
}
