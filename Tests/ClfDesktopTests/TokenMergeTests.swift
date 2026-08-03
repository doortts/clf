import XCTest
@testable import ClfDesktop

private func token(_ name: String, expires: Double, canReadUsage: Bool = true) -> DesktopToken {
    DesktopToken(token: name, subscriptionType: "team", rateLimitTier: nil,
                 expiresAt: Date(timeIntervalSince1970: expires), canReadUsage: canReadUsage)
}

/// 같은 계정의 토큰이 기본 디렉토리와 별도 창 디렉토리에 둘 다 있을 때.
///
/// 별도 창은 씨앗으로 받은 옛 사본을 들고 있을 수 있고, 반대로 그 창에서만
/// 쓴 계정은 그쪽이 유일한 토큰이다. 어느 쪽이든 읽히는 쪽을 골라야 한다.
final class TokenMergeTests: XCTestCase {
    func test_prefersTheOneThatLastsLonger() {
        let old = token("old", expires: 100)
        let new = token("new", expires: 200)
        XCTAssertEqual(DesktopReader.fresher(old, new).token, "new")
        XCTAssertEqual(DesktopReader.fresher(new, old).token, "new")
    }

    /// 사용량을 못 읽는 토큰은 늦게 만료돼도 쓸모가 없다. 스코프가 먼저다.
    func test_scopeBeatsExpiry() {
        let scoped = token("scoped", expires: 100)
        let unscoped = token("unscoped", expires: 900, canReadUsage: false)
        XCTAssertEqual(DesktopReader.fresher(scoped, unscoped).token, "scoped")
        XCTAssertEqual(DesktopReader.fresher(unscoped, scoped).token, "scoped")
    }

    /// 만료 시각을 모르는 쪽은 뒤로 보낸다. 아는 값이 낫다.
    func test_unknownExpiryLoses() {
        let known = token("known", expires: 100)
        let unknown = DesktopToken(token: "unknown", subscriptionType: nil, rateLimitTier: nil,
                                   expiresAt: nil, canReadUsage: true)
        XCTAssertEqual(DesktopReader.fresher(unknown, known).token, "known")
        XCTAssertEqual(DesktopReader.fresher(known, unknown).token, "known")
    }
}
