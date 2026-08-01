import XCTest
@testable import ClflCore

/// docs/porting/02-response-classification.md 8절
final class ClassifierTests: XCTestCase {

    // MARK: 429

    func test_rateLimit_usesRetryAfterHeader() throws { throw XCTSkip("미구현") }

    /// max 를 쓰면 실제 쿨다운이 5시간인데 조직을 37시간 이상 퇴장시킨다.
    func test_rateLimit_prefersRetryAfterOverWeeklyReset() throws { throw XCTSkip("미구현") }

    func test_rateLimit_fallsBackToNearestUpcomingReset() throws { throw XCTSkip("미구현") }

    func test_rateLimit_defaultsTo60sWhenNoResetHeaders() throws { throw XCTSkip("미구현") }

    func test_sessionLimit_emitsSessionLimitTrigger() throws { throw XCTSkip("미구현") }

    func test_auth401_emitsAuthenticationTrigger() throws { throw XCTSkip("미구현") }

    // MARK: 통과 분기

    func test_passthrough_529Overloaded() throws { throw XCTSkip("미구현") }
    func test_passthrough_500ApiError() throws { throw XCTSkip("미구현") }
    func test_passthrough_200Success() throws { throw XCTSkip("미구현") }
    func test_passthrough_429WithUnknownErrorType() throws { throw XCTSkip("미구현") }
    func test_passthrough_401WithNonAuthBody() throws { throw XCTSkip("미구현") }
    func test_passthrough_unparseableBody() throws { throw XCTSkip("미구현") }

    // MARK: resolveResetEpoch 단위

    func test_resetEpoch_skipsAlreadyPassedResets() throws { throw XCTSkip("미구현") }

    /// 서버가 delta-seconds 를 reset 헤더에 넣는 경우를 거른다.
    func test_resetEpoch_ignoresSubEpochHeuristicValues() throws { throw XCTSkip("미구현") }

    // MARK: 스트리밍 첫 이벤트

    /// 200 으로 시작한 스트림의 첫 프레임이 event: error 인 경우가 실제로 있다.
    /// status 만 보면 통째로 놓친다.
    func test_streaming_classifiesErrorFirstFrameOn200() throws { throw XCTSkip("미구현") }

    func test_streaming_passesThroughMessageStart() throws { throw XCTSkip("미구현") }

    // MARK: transient overload

    /// 이 구분이 없으면 시작 시 풀 전체가 60초 암전된다.
    func test_transient_requiresShouldRetryAndAbsenceOfWindowHeaders() throws {
        throw XCTSkip("미구현")
    }

    func test_transient_sessionLimitIsNeverTransient() throws { throw XCTSkip("미구현") }
}
