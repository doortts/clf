import XCTest
@testable import ClfProxy

/// docs/design/04-implementation.md 7절
final class SwapLoopTests: XCTestCase {
    func test_selectsAccountsInPriorityOrderAcross429Sequence() throws { throw XCTSkip("미구현") }
    func test_neverRetriesSameAccountWithinOneRequest() throws { throw XCTSkip("미구현") }
    func test_replaysLastFailedResponseVerbatimOnExhaustion() throws { throw XCTSkip("미구현") }

    /// 가장 중요한 테스트. 판정 전에 writeHead 가 불리면 안 된다.
    func test_noClientWriteBeforeClassificationCommits() throws { throw XCTSkip("미구현") }

    func test_writeHeadCalledExactlyOncePerResponse() throws { throw XCTSkip("미구현") }

    /// 릴레이 중 event: error 가 와도 재분류하지 않고 원문 전달.
    func test_noSecondClassifyAfterFirstByte() throws { throw XCTSkip("미구현") }

    /// end() 를 부르면 잘린 스트림이 완결된 것처럼 보인다.
    func test_midStreamUpstreamFailureAbortsInsteadOfEnding() throws { throw XCTSkip("미구현") }
}

final class CredentialRefreshTests: XCTestCase {
    /// 만료된 토큰이 조직을 태우지 않는다. 사용자는 아무것도 눈치채지 못한다.
    func test_401OnOAuthRefreshesAndRetriesSameAccount() throws { throw XCTSkip("미구현") }

    func test_refreshRejectedMarksAccountInvalid() throws { throw XCTSkip("미구현") }

    /// 네트워크 한 번 끊겼다고 재로그인을 요구하면 안 된다.
    func test_refreshTransientDoesNotInvalidate() throws { throw XCTSkip("미구현") }

    /// 서버가 필드 하나 바꾼 날 모든 조직이 한꺼번에 죽으면 안 된다.
    func test_http200WithUnparseableBodyIsTransientNotRejected() throws { throw XCTSkip("미구현") }

    func test_onlyOneRefreshAttemptPerAccountPerRequest() throws { throw XCTSkip("미구현") }

    func test_concurrentCallersShareSingleInFlightRefresh() throws { throw XCTSkip("미구현") }
}
