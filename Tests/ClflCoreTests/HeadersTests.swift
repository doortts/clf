import XCTest
@testable import ClflCore

/// docs/porting/01-headers-and-auth.md 7절의 케이스 목록을 그대로 옮긴 것.
final class HeadersTests: XCTestCase {

    // MARK: stripClientHopByHop

    func test_stripClientHopByHop_dropsAuthAndHopByHop() {
        let input = HeaderBag([
            "Authorization": "Bearer client-supplied",
            "x-api-key": "client-key",
            "Host": "example.com",
            "Connection": "keep-alive",
            "Transfer-Encoding": "chunked",
            "Proxy-Connection": "keep-alive",
            "content-type": "application/json",
            "anthropic-beta": "claude-code-20250219",
        ])
        let out = ProxyHeaders.stripClientHopByHop(input)
        XCTAssertNil(out["authorization"])
        XCTAssertNil(out["x-api-key"])
        XCTAssertNil(out["host"])
        XCTAssertNil(out["connection"])
        XCTAssertNil(out["transfer-encoding"])
        XCTAssertNil(out["proxy-connection"])
        XCTAssertEqual(out["content-type"], "application/json")
        XCTAssertEqual(out["anthropic-beta"], "claude-code-20250219")
    }

    func test_stripClientHopByHop_lowercasesKeys() {
        let out = ProxyHeaders.stripClientHopByHop(HeaderBag(["Content-Type": "application/json"]))
        XCTAssertEqual(Array(out.storage.keys), ["content-type"])
    }

    // MARK: rewriteAuth, 클래식 API 키 분기

    func test_rewriteAuth_apiKey_setsXApiKey() {
        let out = ProxyHeaders.rewriteAuth(HeaderBag(), token: "sk-ant-api03-abc")
        XCTAssertEqual(out["x-api-key"], "sk-ant-api03-abc")
        XCTAssertNil(out["authorization"])
    }

    func test_rewriteAuth_apiKey_doesNotTouchAnthropicBeta() {
        let out = ProxyHeaders.rewriteAuth(
            HeaderBag(["anthropic-beta": "claude-code-20250219"]), token: "sk-ant-api03-abc")
        XCTAssertEqual(out["anthropic-beta"], "claude-code-20250219")
    }

    // MARK: rewriteAuth, OAuth 분기. 함정 1, 2, 3 을 잠근다

    /// OAuth 토큰을 x-api-key 로 보내면 401 "invalid x-api-key" 가 나고
    /// 모든 조직이 차례로 invalid 처리되어 체인이 즉시 소진된다.
    func test_rewriteAuth_oauth_setsBearerAndBetaFlag() {
        let out = ProxyHeaders.rewriteAuth(HeaderBag(), token: "sk-ant-oat01-xyz")
        XCTAssertEqual(out["authorization"], "Bearer sk-ant-oat01-xyz")
        XCTAssertEqual(out["anthropic-beta"], "oauth-2025-04-20")
        XCTAssertNil(out["x-api-key"], "OAuth 토큰은 x-api-key 로 절대 나가면 안 된다")
    }

    func test_rewriteAuth_oauth_mergesExistingBetaWithoutDuplicating() {
        let out = ProxyHeaders.rewriteAuth(
            HeaderBag(["anthropic-beta": "claude-code-20250219"]), token: "sk-ant-oat01-xyz")
        XCTAssertEqual(out["anthropic-beta"], "claude-code-20250219, oauth-2025-04-20")
    }

    func test_rewriteAuth_oauth_isIdempotentWhenFlagAlreadyPresent() {
        let once = ProxyHeaders.rewriteAuth(
            HeaderBag(["anthropic-beta": "oauth-2025-04-20"]), token: "sk-ant-oat01-xyz")
        XCTAssertEqual(once["anthropic-beta"], "oauth-2025-04-20")
        let twice = ProxyHeaders.rewriteAuth(once, token: "sk-ant-oat01-xyz")
        XCTAssertEqual(twice["anthropic-beta"], "oauth-2025-04-20")
    }

    func test_rewriteAuth_oauth_normalizesMixedCaseBetaKey() {
        let out = ProxyHeaders.rewriteAuth(
            HeaderBag(["Anthropic-Beta": "claude-code-20250219"]), token: "sk-ant-oat01-xyz")
        XCTAssertEqual(out["anthropic-beta"], "claude-code-20250219, oauth-2025-04-20")
        XCTAssertEqual(out.storage.keys.filter { $0 == "anthropic-beta" }.count, 1)
    }

    func test_rewriteAuth_doesNotMutateInput() {
        let input = HeaderBag(["anthropic-beta": "claude-code-20250219"])
        _ = ProxyHeaders.rewriteAuth(input, token: "sk-ant-oat01-xyz")
        XCTAssertEqual(input["anthropic-beta"], "claude-code-20250219")
        XCTAssertNil(input["authorization"])
    }

    // MARK: injectAnthropicVersion

    func test_injectAnthropicVersion_addsWhenAbsent() {
        let out = ProxyHeaders.injectAnthropicVersion(HeaderBag())
        XCTAssertEqual(out["anthropic-version"], ProxyHeaders.defaultAnthropicVersion)
    }

    func test_injectAnthropicVersion_preservesClientValueVerbatim() {
        let out = ProxyHeaders.injectAnthropicVersion(HeaderBag(["anthropic-version": "2099-01-01"]))
        XCTAssertEqual(out["anthropic-version"], "2099-01-01")
    }

    func test_injectAnthropicVersion_detectionIsCaseInsensitive() {
        let out = ProxyHeaders.injectAnthropicVersion(HeaderBag(["Anthropic-Version": "2099-01-01"]))
        XCTAssertEqual(out["anthropic-version"], "2099-01-01")
    }

    // MARK: buildUpstreamURL

    func test_buildUpstreamURL_joinsBaseAndPath() {
        XCTAssertEqual(
            ProxyHeaders.buildUpstreamURL(baseURL: "https://api.anthropic.com", requestURI: "/v1/messages"),
            "https://api.anthropic.com/v1/messages")
    }

    func test_buildUpstreamURL_handlesTrailingSlashIdempotently() {
        XCTAssertEqual(
            ProxyHeaders.buildUpstreamURL(baseURL: "https://api.anthropic.com/", requestURI: "/v1/messages"),
            "https://api.anthropic.com/v1/messages")
    }

    /// URLComponents 를 쓰면 여기서 재인코딩이 일어난다.
    func test_buildUpstreamURL_preservesQueryVerbatim() {
        XCTAssertEqual(
            ProxyHeaders.buildUpstreamURL(baseURL: "https://api.anthropic.com",
                                          requestURI: "/v1/models?limit=20&after_id=a%2Fb"),
            "https://api.anthropic.com/v1/models?limit=20&after_id=a%2Fb")
    }

    func test_buildUpstreamURL_supportsEnterprisePathPrefix() {
        XCTAssertEqual(
            ProxyHeaders.buildUpstreamURL(baseURL: "https://gw.example.com/anthropic",
                                          requestURI: "/v1/messages"),
            "https://gw.example.com/anthropic/v1/messages")
    }

    // MARK: pickResponseHeaders

    func test_pickResponseHeaders_dropsHopByHopAndContentLength() {
        let out = ProxyHeaders.pickResponseHeaders(HeaderBag([
            "Content-Length": "1234",
            "Connection": "keep-alive",
            "Transfer-Encoding": "chunked",
            "Content-Type": "text/event-stream",
            "anthropic-ratelimit-unified-5h-remaining": "100",
        ]), clientDecodedBody: true)
        XCTAssertNil(out["content-length"])
        XCTAssertNil(out["connection"])
        XCTAssertNil(out["transfer-encoding"])
        XCTAssertEqual(out["content-type"], "text/event-stream")
        XCTAssertEqual(out["anthropic-ratelimit-unified-5h-remaining"], "100")
    }

    /// 업스트림 자동 해제를 켰으므로 평문을 내보낸다. 헤더를 남기면 클라이언트가
    /// 두 번째 해제를 시도해 ZlibError 가 난다.
    func test_pickResponseHeaders_dropsContentEncodingWhenDecoded() {
        let out = ProxyHeaders.pickResponseHeaders(
            HeaderBag(["content-encoding": "gzip"]), clientDecodedBody: true)
        XCTAssertNil(out["content-encoding"])
    }

    /// 해제하지 않은 경로의 회귀 가드. 압축 바이트를 그대로 릴레이하면 헤더도 남겨야 한다.
    func test_pickResponseHeaders_keepsContentEncodingWhenNotDecoded() {
        let out = ProxyHeaders.pickResponseHeaders(
            HeaderBag(["content-encoding": "gzip"]), clientDecodedBody: false)
        XCTAssertEqual(out["content-encoding"], "gzip")
    }
}
