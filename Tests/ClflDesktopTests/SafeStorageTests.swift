import XCTest
@testable import ClflDesktop

/// Chromium safe storage 와 앱의 토큰 캐시.
/// docs/design/10-desktop-usage.md 2절
final class SafeStorageTests: XCTestCase {

    /// PBKDF2-SHA1(pw, "saltysalt", 1003회, 16바이트). Chromium 이 쓰는 그대로다.
    /// 기대값은 같은 파라미터로 독립 계산해 고정했다. 파라미터가 하나라도
    /// 바뀌면 실제 앱 데이터를 못 풀게 되므로 여기서 잡는다.
    func test_keyDerivationIsDeterministic() throws {
        let key = try safeStorageKey(password: "peanuts")
        XCTAssertEqual(key.count, 16)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(),
                       "d9a09d499b4e1b7461f28e67972c6dbd")
    }

    func test_sameInputSameKey() throws {
        XCTAssertEqual(try safeStorageKey(password: "abc"), try safeStorageKey(password: "abc"))
        XCTAssertNotEqual(try safeStorageKey(password: "abc"), try safeStorageKey(password: "abd"))
    }

    // MARK: 복호화

    func test_roundTrip() throws {
        let key = try safeStorageKey(password: "test-pw")
        let secret = "746e81ae-c1e7-4402-a1af-7a3cf49a7fa5"
        let encrypted = try encryptV10(Data(secret.utf8), key: key)
        XCTAssertEqual(String(decoding: try decryptV10(encrypted, key: key), as: UTF8.self),
                       secret)
    }

    func test_v10PrefixIsRequired() throws {
        let key = try safeStorageKey(password: "x")
        let plain = Data("그냥 평문".utf8)
        // 접두사가 없으면 암호문이 아니다. 그대로 돌려준다
        XCTAssertEqual(try decryptV10(plain, key: key), plain)
    }

    /// 쿠키 평문은 SHA256(host) 32바이트가 앞에 붙는다. 토큰 캐시는 안 붙는다.
    func test_stripsDomainHashPrefix() {
        let body = Data("값".utf8)
        let withPrefix = Data(repeating: 0xAB, count: 32) + body
        XCTAssertEqual(stripDomainHash(withPrefix), body)
    }

    func test_shortPlaintextIsLeftAlone() {
        let short = Data("짧다".utf8)
        XCTAssertEqual(stripDomainHash(short), short)
    }

    // MARK: 토큰 캐시

    /// 캐시 키가 clientId:orgId:host:scopes 형식이다. 콜론이 스코프에도 들어 있어
    /// 앞에서 두 번째 조각만 떼야 한다.
    func test_extractsOrgFromCacheKey() throws {
        let json = Data("""
        {"9d1c250a-e61b-44d9-88ed-5944d1962f5e:746e81ae-c1e7-4402-a1af-7a3cf49a7fa5:https://api.anthropic.com:user:inference user:file_upload user:profile":
          {"token":"sk-ant-oat01-aaa","refreshToken":"r","expiresAt":1800000000000,
           "subscriptionType":"team","rateLimitTier":"default_claude_max_5x"}}
        """.utf8)
        let cache = try parseTokenCache(json)
        XCTAssertEqual(cache.count, 1)
        let entry = try XCTUnwrap(cache["746e81ae-c1e7-4402-a1af-7a3cf49a7fa5"])
        XCTAssertEqual(entry.token, "sk-ant-oat01-aaa")
        XCTAssertEqual(entry.subscriptionType, "team")
    }

    func test_keepsAllOrgs() throws {
        let json = Data("""
        {"c:111:h:s": {"token":"a"}, "c:222:h:s": {"token":"b"}}
        """.utf8)
        XCTAssertEqual(Set(try parseTokenCache(json).keys), ["111", "222"])
    }

    /// Usage API 는 user:profile 을 요구한다. 없는 토큰은 부를 필요가 없다.
    func test_reportsProfileScope() throws {
        let json = Data("""
        {"c:111:h:user:inference user:profile": {"token":"a"},
         "c:222:h:user:inference":              {"token":"b"}}
        """.utf8)
        let cache = try parseTokenCache(json)
        XCTAssertTrue(cache["111"]!.canReadUsage)
        XCTAssertFalse(cache["222"]!.canReadUsage)
    }

    func test_ignoresMalformedKeys() throws {
        let json = Data(#"{"nocolons": {"token":"a"}, "c:222:h:s": {"token":"b"}}"#.utf8)
        XCTAssertEqual(Array(try parseTokenCache(json).keys), ["222"])
    }

    func test_malformedCacheThrows() {
        XCTAssertThrowsError(try parseTokenCache(Data("nope".utf8)))
    }
}
