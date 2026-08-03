import XCTest
@testable import ClfCore

/// docs/porting/02-response-classification.md 8절
final class ClassifierTests: XCTestCase {

    let now = 1_700_000_000

    func body(_ type: String) -> Data {
        Data(#"{"type":"error","error":{"type":"\#(type)","message":"x"}}"#.utf8)
    }
    func input(status: Int, type: String? = nil, headers: [String: String] = [:],
               sse: SSEEvent? = nil, rawBody: Data? = nil) -> ClassifyInput {
        ClassifyInput(status: status, headers: HeaderBag(headers),
                      body: rawBody ?? type.map(body), firstSSEEvent: sse,
                      accountID: "team1", sessionID: "s1", now: now)
    }

    // MARK: 429

    func test_rateLimit_usesRetryAfterHeader() {
        let t = classifyResponse(input(status: 429, type: "rate_limit_error",
                                       headers: ["retry-after": "120"]))
        XCTAssertEqual(t, .rateLimit(accountID: "team1", resetEpoch: now + 120, sessionID: "s1"))
    }

    /// max 를 쓰면 실제 쿨다운이 5시간인데 조직을 37시간 이상 퇴장시킨다.
    func test_rateLimit_prefersRetryAfterOverWeeklyReset() {
        let t = classifyResponse(input(status: 429, type: "rate_limit_error", headers: [
            "retry-after": "300",
            "anthropic-ratelimit-unified-7d-reset": "\(now + 600_000)",
        ]))
        XCTAssertEqual(t, .rateLimit(accountID: "team1", resetEpoch: now + 300, sessionID: "s1"))
    }

    func test_rateLimit_fallsBackToNearestUpcomingReset() {
        let t = classifyResponse(input(status: 429, type: "rate_limit_error", headers: [
            "anthropic-ratelimit-unified-7d-reset": "\(now + 600_000)",
            "anthropic-ratelimit-unified-5h-reset": "\(now + 18_000)",
        ]))
        XCTAssertEqual(t, .rateLimit(accountID: "team1", resetEpoch: now + 18_000, sessionID: "s1"))
    }

    func test_rateLimit_defaultsTo60sWhenNoResetHeaders() {
        let t = classifyResponse(input(status: 429, type: "rate_limit_error"))
        XCTAssertEqual(t, .rateLimit(accountID: "team1", resetEpoch: now + 60, sessionID: "s1"))
    }

    func test_sessionLimit_emitsSessionLimitTrigger() {
        let t = classifyResponse(input(status: 429, type: "session_limit_error",
                                       headers: ["retry-after": "90"]))
        XCTAssertEqual(t, .sessionLimit(accountID: "team1", resetEpoch: now + 90, sessionID: "s1"))
    }

    func test_auth401_emitsAuthenticationTrigger() {
        let t = classifyResponse(input(status: 401, type: "authentication_error"))
        XCTAssertEqual(t, .authentication(accountID: "team1", sessionID: "s1"))
    }

    // MARK: 통과 분기

    func test_passthrough_529Overloaded() {
        XCTAssertNil(classifyResponse(input(status: 529, type: "overloaded_error")))
    }
    func test_passthrough_500ApiError() {
        XCTAssertNil(classifyResponse(input(status: 500, type: "api_error")))
    }
    func test_passthrough_200Success() {
        XCTAssertNil(classifyResponse(input(status: 200,
            rawBody: Data(#"{"type":"message","content":[]}"#.utf8))))
    }
    /// 스왑 집합에 없는 타입은 건드리지 않는다.
    func test_passthrough_429WithUnknownErrorType() {
        XCTAssertNil(classifyResponse(input(status: 429, type: "invalid_request_error")))
    }
    /// status 만으로 판단 금지.
    func test_passthrough_401WithNonAuthBody() {
        XCTAssertNil(classifyResponse(input(status: 401, type: "permission_error")))
    }
    func test_passthrough_unparseableBody() {
        XCTAssertNil(classifyResponse(input(status: 429, rawBody: Data("not json".utf8))))
    }
    func test_passthrough_emptyBody() {
        XCTAssertNil(classifyResponse(input(status: 429, rawBody: Data())))
    }
    /// rate_limit_error 라도 429 가 아니고 스트리밍 오류도 아니면 통과.
    func test_passthrough_rateLimitTypeOnNon429NonStream() {
        XCTAssertNil(classifyResponse(input(status: 200, type: "rate_limit_error")))
    }

    // MARK: resolveResetEpoch 단위

    func test_resetEpoch_skipsAlreadyPassedResets() {
        let h = HeaderBag([
            "anthropic-ratelimit-unified-5h-reset": "\(now - 10)",
            "anthropic-ratelimit-unified-7d-reset": "\(now + 5_000)",
        ])
        XCTAssertEqual(resolveResetEpoch(h, now: now), now + 5_000)
    }

    /// 서버가 delta-seconds 를 reset 헤더에 넣는 경우를 거른다.
    func test_resetEpoch_ignoresSubEpochHeuristicValues() {
        let h = HeaderBag(["anthropic-ratelimit-unified-5h-reset": "300"])
        XCTAssertEqual(resolveResetEpoch(h, now: now), now + defaultCooldownSeconds)
    }

    func test_resetEpoch_ignoresNonResetRatelimitHeaders() {
        let h = HeaderBag(["anthropic-ratelimit-unified-5h-remaining": "\(now + 5_000)"])
        XCTAssertEqual(resolveResetEpoch(h, now: now), now + defaultCooldownSeconds)
    }

    /// Int("120s") 는 nil 이라 폴백으로 떨어진다. JS parseInt 와 다른 지점.
    func test_resetEpoch_unparseableRetryAfterFallsThrough() {
        let h = HeaderBag(["retry-after": "Wed, 21 Oct 2099 07:28:00 GMT"])
        XCTAssertEqual(resolveResetEpoch(h, now: now), now + defaultCooldownSeconds)
    }

    // MARK: 스트리밍 첫 이벤트

    /// 200 으로 시작한 스트림의 첫 프레임이 event: error 인 경우가 실제로 있다.
    func test_streaming_classifiesErrorFirstFrameOn200() {
        let sse = SSEEvent(event: "error",
                           data: #"{"type":"error","error":{"type":"rate_limit_error"}}"#)
        let t = classifyResponse(input(status: 200, headers: ["retry-after": "45"],
                                       sse: sse, rawBody: Data()))
        XCTAssertEqual(t, .rateLimit(accountID: "team1", resetEpoch: now + 45, sessionID: "s1"))
    }

    func test_streaming_passesThroughMessageStart() {
        let sse = SSEEvent(event: "message_start",
                           data: #"{"type":"message_start","message":{"id":"m1"}}"#)
        XCTAssertNil(classifyResponse(input(status: 200, sse: sse, rawBody: Data())))
    }

    // MARK: transient overload

    /// 이 구분이 없으면 시작 시 풀 전체가 60초 암전된다.
    func test_transient_requiresShouldRetryAndAbsenceOfWindowHeaders() {
        let trigger = SwapTrigger.rateLimit(accountID: "t", resetEpoch: 0, sessionID: "s")
        XCTAssertTrue(isTransientOverload(headers: HeaderBag(["x-should-retry": "true"]),
                                          trigger: trigger))
        // 창 헤더가 있으면 진짜 한도다
        XCTAssertFalse(isTransientOverload(headers: HeaderBag([
            "x-should-retry": "true",
            "anthropic-ratelimit-unified-5h-remaining": "0",
        ]), trigger: trigger))
        // 신호가 없으면 transient 가 아니다
        XCTAssertFalse(isTransientOverload(headers: HeaderBag(), trigger: trigger))
    }

    func test_transient_sessionLimitIsNeverTransient() {
        let trigger = SwapTrigger.sessionLimit(accountID: "t", resetEpoch: 0, sessionID: "s")
        XCTAssertFalse(isTransientOverload(headers: HeaderBag(["x-should-retry": "true"]),
                                           trigger: trigger))
    }

    func test_transient_authenticationIsNeverTransient() {
        let trigger = SwapTrigger.authentication(accountID: "t", sessionID: "s")
        XCTAssertFalse(isTransientOverload(headers: HeaderBag(["x-should-retry": "true"]),
                                           trigger: trigger))
    }
}
