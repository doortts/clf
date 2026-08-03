import XCTest
import ClfCore
@testable import ClfStore

final class StoredCredentialTests: XCTestCase {
    func test_longLivedRoundTrip() {
        let value = StoredCredential.longLived(token: "sk-ant-oat01-abc")
        XCTAssertEqual(StoredCredential(wireFormat: value.wireFormat), value)
    }

    func test_oauthRoundTrip() {
        let value = StoredCredential.oauth(json: Data(#"{"claudeAiOauth":{"a":1}}"#.utf8))
        XCTAssertEqual(StoredCredential(wireFormat: value.wireFormat), value)
    }

    /// 내용으로 추측하지 않는다. 태그가 종류를 말한다.
    func test_tagDecidesKindNotContent() {
        let jsonLookingToken = StoredCredential.longLived(token: #"{"looks":"like json"}"#)
        XCTAssertEqual(StoredCredential(wireFormat: jsonLookingToken.wireFormat),
                       jsonLookingToken)
    }

    func test_unknownWireFormatIsRejected() {
        XCTAssertNil(StoredCredential(wireFormat: "sk-ant-oat01-no-tag"))
        XCTAssertNil(StoredCredential(wireFormat: ""))
    }
}

final class OAuthCredentialTests: XCTestCase {
    let wrapped = Data("""
    {"claudeAiOauth":{"accessToken":"sk-ant-oat01-a","refreshToken":"sk-ant-ort01-r",
     "expiresAt":1800000000000,"scopes":["user:inference","user:profile"],
     "subscriptionType":"team"}}
    """.utf8)

    func test_parsesWrappedBlock() throws {
        let c = try XCTUnwrap(OAuthCredential(claudeAiOauthJSON: wrapped))
        XCTAssertEqual(c.accessToken, "sk-ant-oat01-a")
        XCTAssertEqual(c.refreshToken, "sk-ant-ort01-r")
        XCTAssertEqual(c.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(c.subscriptionType, "team")
    }

    func test_parsesBareBlock() throws {
        let inner = try XCTUnwrap(
            JSONSerialization.jsonObject(with: wrapped) as? [String: Any])["claudeAiOauth"]
        let bare = try JSONSerialization.data(withJSONObject: try XCTUnwrap(inner))
        XCTAssertEqual(OAuthCredential(claudeAiOauthJSON: bare)?.accessToken, "sk-ant-oat01-a")
    }

    func test_acceptsSpaceJoinedScopes() throws {
        let data = Data(#"""
        {"accessToken":"a","refreshToken":"r","expiresAt":1800000000000,
         "scopes":"user:inference user:profile"}
        """#.utf8)
        XCTAssertEqual(OAuthCredential(claudeAiOauthJSON: data)?.scopes,
                       ["user:inference", "user:profile"])
    }

    /// Usage API 가 없으면 모델별 주간 한도를 영영 못 읽는다. setup-token 과
    /// auth login 캡처를 가르는 실질적 차이다.
    func test_usageAPIRequiresProfileScope() {
        XCTAssertTrue(OAuthCredential(claudeAiOauthJSON: wrapped)!.canReadUsageAPI)

        let inferenceOnly = Data(#"""
        {"accessToken":"a","refreshToken":"r","expiresAt":1,"scopes":["user:inference"]}
        """#.utf8)
        XCTAssertFalse(OAuthCredential(claudeAiOauthJSON: inferenceOnly)!.canReadUsageAPI)
    }

    func test_rejectsMissingFields() {
        XCTAssertNil(OAuthCredential(claudeAiOauthJSON: Data(#"{"accessToken":""}"#.utf8)))
        XCTAssertNil(OAuthCredential(claudeAiOauthJSON: Data("not json".utf8)))
    }
}

final class InMemoryCredentialStoreTests: XCTestCase {
    func test_storeAndRead() throws {
        let store = InMemoryCredentialStore()
        XCTAssertFalse(store.hasCredential(for: "a"))

        try store.store(.longLived(token: "t"), for: "a")
        XCTAssertTrue(store.hasCredential(for: "a"))
        XCTAssertEqual(try store.credential(for: "a"), .longLived(token: "t"))

        try store.remove("a")
        XCTAssertFalse(store.hasCredential(for: "a"))
    }

    func test_missingCredentialThrows() {
        XCTAssertThrowsError(try InMemoryCredentialStore().credential(for: "ghost")) {
            XCTAssertEqual($0 as? StoreError, .credentialMissing("ghost"))
        }
    }
}

/// 실제 Keychain 을 건드린다. CI 와 잠긴 로그인 세션에서는 건너뛴다.
///
/// 서비스 이름을 테스트 전용으로 갈라 두어 사용자의 진짜 항목과 섞이지 않는다.
final class KeychainCredentialStoreTests: XCTestCase {
    let service = "me.clf.test.\(UUID().uuidString)"
    lazy var store = KeychainCredentialStore(service: service)

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["CLF_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("CLF_KEYCHAIN_TESTS=1 일 때만 돈다. 잠금 해제 프롬프트를 띄운다")
        }
    }
    override func tearDown() { try? store.remove("a") }

    func test_roundTrip() throws {
        try store.store(.oauth(json: Data(#"{"x":1}"#.utf8)), for: "a")
        XCTAssertEqual(try store.credential(for: "a"), .oauth(json: Data(#"{"x":1}"#.utf8)))
    }

    func test_storeOverwritesExistingItem() throws {
        try store.store(.longLived(token: "one"), for: "a")
        try store.store(.longLived(token: "two"), for: "a")
        XCTAssertEqual(try store.credential(for: "a"), .longLived(token: "two"))
    }

    /// 호출부가 존재를 먼저 확인하지 않아도 된다.
    func test_removingMissingItemSucceeds() throws {
        XCTAssertNoThrow(try store.remove("never-existed"))
    }

    func test_hasCredentialDoesNotReadTheSecret() throws {
        XCTAssertFalse(store.hasCredential(for: "a"))
        try store.store(.longLived(token: "t"), for: "a")
        XCTAssertTrue(store.hasCredential(for: "a"))
    }
}
