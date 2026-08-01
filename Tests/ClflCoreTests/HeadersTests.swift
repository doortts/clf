import XCTest
@testable import ClflCore

/// docs/porting/01-headers-and-auth.md 7절의 케이스 목록.
/// 구현 전이라 전부 skip 이다. skip 이 남아 있는 동안은 미구현이라는 뜻이다.
final class HeadersTests: XCTestCase {

    func test_stripClientHopByHop_dropsAuthAndHopByHop() throws {
        throw XCTSkip("미구현: ProxyHeaders.stripClientHopByHop")
    }

    func test_stripClientHopByHop_lowercasesKeys() throws {
        throw XCTSkip("미구현")
    }

    // MARK: 클래식 API 키 분기

    func test_rewriteAuth_apiKey_setsXApiKey() throws {
        throw XCTSkip("미구현")
    }

    func test_rewriteAuth_apiKey_doesNotTouchAnthropicBeta() throws {
        throw XCTSkip("미구현")
    }

    // MARK: OAuth 분기. 함정 1, 2, 3 을 잠그는 회귀 테스트

    /// OAuth 토큰을 x-api-key 로 보내면 401 "invalid x-api-key" 가 나고 모든 조직이
    /// 차례로 invalid 처리되어 체인이 즉시 소진된다.
    func test_rewriteAuth_oauth_setsBearerAndBetaFlag() throws {
        throw XCTSkip("미구현")
    }

    func test_rewriteAuth_oauth_mergesExistingBetaWithoutDuplicating() throws {
        throw XCTSkip("미구현")
    }

    func test_rewriteAuth_oauth_isIdempotentWhenFlagAlreadyPresent() throws {
        throw XCTSkip("미구현")
    }

    func test_rewriteAuth_oauth_normalizesMixedCaseBetaKey() throws {
        throw XCTSkip("미구현")
    }

    func test_rewriteAuth_doesNotMutateInput() throws {
        throw XCTSkip("미구현")
    }

    // MARK: 나머지

    func test_injectAnthropicVersion_addsWhenAbsent() throws {
        throw XCTSkip("미구현")
    }

    func test_injectAnthropicVersion_preservesClientValueVerbatim() throws {
        throw XCTSkip("미구현")
    }

    func test_buildUpstreamURL_handlesTrailingSlashIdempotently() throws {
        throw XCTSkip("미구현")
    }

    func test_buildUpstreamURL_preservesQueryVerbatim() throws {
        throw XCTSkip("미구현")
    }

    func test_buildUpstreamURL_supportsEnterprisePathPrefix() throws {
        throw XCTSkip("미구현")
    }

    func test_pickResponseHeaders_dropsHopByHopAndContentLength() throws {
        throw XCTSkip("미구현")
    }

    /// Swift 전용. 해제하지 않은 경로의 회귀 가드.
    func test_pickResponseHeaders_keepsContentEncodingWhenNotDecoded() throws {
        throw XCTSkip("미구현")
    }
}
