import XCTest
@testable import ClfStore

/// `security find-generic-password -w` 는 값에 출력 불가 바이트가 하나라도 있으면
/// 원문 대신 16진수를 낸다. 그것을 그대로 파싱하면 "형식을 알 수 없다" 로 죽는다.
final class SecurityHexOutputTests: XCTestCase {

    func test_plainValuePassesThrough() {
        XCTAssertEqual(decodeSecurityOutput("L:sk-ant-oat01-abc"), "L:sk-ant-oat01-abc")
        XCTAssertEqual(decodeSecurityOutput(#"{"claudeAiOauth":{}}"#), #"{"claudeAiOauth":{}}"#)
    }

    /// 우리 형식은 L: 또는 O: 로 시작하고 Claude CLI 슬롯은 { 로 시작한다.
    /// 셋 다 소문자 16진수 집합 밖이라 hex 출력과 겹치지 않는다.
    func test_hexOutputIsDecoded() {
        let original = "L:sk-ant-oat01-abc"
        let hex = original.utf8.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(decodeSecurityOutput(hex), original)
    }

    func test_decodesRealWorldContaminatedValue() {
        // 터미널 프롬프트 장식(U+E0B2)과 줄바꿈이 섞인 값
        let original = "L:sk-ant-oat01-abc\u{E0B2}\ndef"
        let hex = Array(original.utf8).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(decodeSecurityOutput(hex), original)
    }

    func test_oddLengthHexIsNotTreatedAsHex() {
        XCTAssertEqual(decodeSecurityOutput("abc"), "abc")
    }

    func test_emptyStaysEmpty() {
        XCTAssertEqual(decodeSecurityOutput(""), "")
    }

    /// 소문자 16진수만 hex 로 본다. 대문자가 섞이면 원문이다.
    func test_uppercaseIsNotHex() {
        XCTAssertEqual(decodeSecurityOutput("4C3A"), "4C3A")
    }
}

/// 붙여넣기 오염을 등록 시점에 막는다.
///
/// 터미널에서 토큰을 복사하면 프롬프트 장식이나 줄바꿈이 함께 딸려온다.
/// 그대로 저장하면 업스트림이 401 을 내고 사용자는 토큰이 틀렸다고 생각한다.
final class TokenHygieneTests: XCTestCase {

    func test_cleanTokenPasses() throws {
        XCTAssertNoThrow(try validateTokenText("sk-ant-oat01-abcDEF_123-xyz"))
    }

    func test_oauthJSONPasses() throws {
        XCTAssertNoThrow(try validateTokenText(#"{"claudeAiOauth":{"accessToken":"a b"}}"#))
    }

    func test_rejectsPrivateUseGlyphs() {
        // Powerline, Nerd Font 프롬프트 장식
        assertRejected("sk-ant-oat01-abc\u{E0B2}def", contains: "U+E0B2")
    }

    func test_rejectsEmbeddedNewline() {
        assertRejected("sk-ant-oat01-abc\ndef", contains: "줄바꿈")
    }

    func test_rejectsEmbeddedSpace() {
        assertRejected("sk-ant-oat01-abc def", contains: "공백")
    }

    /// 어디가 오염됐는지 말해야 사용자가 다시 복사할 수 있다.
    func test_reportsPosition() {
        do {
            try validateTokenText("sk-ant\u{E0B2}")
            XCTFail("거부해야 한다")
        } catch let error as TokenHygieneError {
            XCTAssertTrue(error.description.contains("7번째"), error.description)
        } catch {
            XCTFail("TokenHygieneError 여야 한다")
        }
    }

    func test_rejectsEmpty() {
        assertRejected("", contains: "비었다")
    }

    private func assertRejected(_ text: String, contains needle: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        do {
            try validateTokenText(text)
            XCTFail("거부해야 한다", file: file, line: line)
        } catch {
            XCTAssertTrue("\(error)".contains(needle),
                          "메시지에 \(needle) 이 없다: \(error)", file: file, line: line)
        }
    }
}
