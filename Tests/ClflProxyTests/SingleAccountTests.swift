import XCTest
import NIOCore
import ClflCore
import ClflStore
@testable import ClflProxy

private let T0 = Date(timeIntervalSince1970: 1_700_000_000)

private func acct(_ id: String = "team1", baseURL: String? = nil) -> Account {
    Account(id: id, plan: .team, baseURL: baseURL.flatMap(URL.init(string:)),
            credentialKind: .oauth, tokenCreatedAt: T0, tokenFingerprint: "fp")
}

/// 업스트림에 무엇을 보냈는지 기록하고 정해진 답을 낸다.
final class FakeExecutor: UpstreamExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [UpstreamRequest] = []
    var sent: [UpstreamRequest] { lock.lock(); defer { lock.unlock() }; return _sent }

    var reply: @Sendable () throws -> UpstreamAttempt = {
        .buffered(status: 200, headers: HeaderBag(),
                  body: Array(#"{"ok":1}"#.utf8), isSSE: false)
    }

    func execute(_ req: UpstreamRequest) async throws -> UpstreamAttempt {
        record(req)
        return try reply()
    }
    private func record(_ req: UpstreamRequest) {
        lock.lock(); defer { lock.unlock() }
        _sent.append(req)
    }
}

final class CapturingTraces: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [RequestTrace] = []
    var items: [RequestTrace] { lock.lock(); defer { lock.unlock() }; return _items }
    func record(_ trace: RequestTrace) { lock.lock(); _items.append(trace); lock.unlock() }
}

final class CapturingSink: EventSinking, @unchecked Sendable {
    private let lock = NSLock()
    private var _usage: [UsageRecord] = []
    private var _events: [RoutingEvent] = []
    var usage: [UsageRecord] { lock.lock(); defer { lock.unlock() }; return _usage }
    var events: [RoutingEvent] { lock.lock(); defer { lock.unlock() }; return _events }

    func append(_ event: RoutingEvent) { lock.lock(); _events.append(event); lock.unlock() }
    func append(_ usage: UsageRecord)  { lock.lock(); _usage.append(usage); lock.unlock() }
}

/// 8단계. 스왑 없이 조직 하나로만 통과시킨다.
final class SingleAccountHandlerTests: XCTestCase {

    var executor: FakeExecutor!
    var store: InMemoryCredentialStore!
    var sink: CapturingSink!
    var client: RecordingClient!
    var traces: CapturingTraces!

    override func setUp() {
        executor = FakeExecutor()
        store = InMemoryCredentialStore()
        sink = CapturingSink()
        client = RecordingClient()
        traces = CapturingTraces()
    }

    func handler(_ account: Account = acct(),
                 token: String = "sk-ant-oat01-abc") -> SingleAccountHandler {
        try? store.store(.longLived(token: token), for: account.id)
        let recorder = traces!
        return SingleAccountHandler(
            account: account,
            tokens: StoredTokenProvider(store: store),
            executor: executor, events: sink,
            trace: { recorder.record($0) })
    }

    func send(_ h: SingleAccountHandler,
              method: String = "POST", uri: String = "/v1/messages",
              headers: HeaderBag = HeaderBag(),
              body: [UInt8] = Array(#"{"model":"x"}"#.utf8)) async {
        await h.handle(method: method, uri: uri, headers: headers, body: body, client: client)
    }

    // MARK: 요청 재작성

    /// OAuth 토큰을 x-api-key 로 보내면 401 이 나고 조직이 무효 처리된다.
    func test_oauthTokenGoesAsBearerWithBetaFlag() async {
        await send(handler())
        let sent = executor.sent.first!
        XCTAssertEqual(sent.headers["authorization"], "Bearer sk-ant-oat01-abc")
        XCTAssertEqual(sent.headers["anthropic-beta"], "oauth-2025-04-20")
        XCTAssertNil(sent.headers["x-api-key"])
    }

    func test_classicKeyGoesAsApiKey() async {
        await send(handler(token: "sk-ant-api03-classic"))
        let sent = executor.sent.first!
        XCTAssertEqual(sent.headers["x-api-key"], "sk-ant-api03-classic")
        XCTAssertNil(sent.headers["authorization"])
        XCTAssertNil(sent.headers["anthropic-beta"], "클래식 키에는 beta 를 붙이지 않는다")
    }

    /// Claude Code 가 claude-code-* 플래그를 이미 보낸다. 덮어쓰면 안 된다.
    func test_mergesIntoExistingBetaFlags() async {
        var headers = HeaderBag()
        headers["anthropic-beta"] = "claude-code-20250219"
        await send(handler(), headers: headers)
        XCTAssertEqual(executor.sent.first?.headers["anthropic-beta"],
                       "claude-code-20250219, oauth-2025-04-20")
    }

    /// 클라이언트가 보낸 authorization 은 오염된 것으로 본다. host 는 업스트림이 정한다.
    func test_stripsClientHopByHopAndAuth() async {
        var headers = HeaderBag()
        headers["authorization"] = "Bearer someone-elses"
        headers["host"] = "127.0.0.1:51710"
        headers["connection"] = "keep-alive"
        headers["transfer-encoding"] = "chunked"
        headers["x-custom"] = "kept"

        await send(handler(), headers: headers)
        let sent = executor.sent.first!
        XCTAssertEqual(sent.headers["authorization"], "Bearer sk-ant-oat01-abc")
        XCTAssertNil(sent.headers["host"])
        XCTAssertNil(sent.headers["connection"])
        XCTAssertNil(sent.headers["transfer-encoding"])
        XCTAssertEqual(sent.headers["x-custom"], "kept")
    }

    func test_injectsAnthropicVersionOnlyWhenAbsent() async {
        await send(handler())
        XCTAssertEqual(executor.sent.first?.headers["anthropic-version"], "2023-06-01")

        var headers = HeaderBag()
        headers["anthropic-version"] = "2099-01-01"
        await send(handler(), headers: headers)
        XCTAssertEqual(executor.sent.last?.headers["anthropic-version"], "2099-01-01",
                       "클라이언트가 보낸 값을 보존한다")
    }

    /// URLComponents 정규화가 기업 게이트웨이의 path prefix 를 망가뜨린다.
    func test_buildsUrlByConcatenationPreservingQuery() async {
        await send(handler(acct(baseURL: "https://gw.example.com/anthropic")),
                   uri: "/v1/messages?beta=true&x=a%2Bb")
        XCTAssertEqual(executor.sent.first?.url,
                       "https://gw.example.com/anthropic/v1/messages?beta=true&x=a%2Bb")
    }

    func test_defaultsToAnthropicWhenNoBaseURL() async {
        await send(handler())
        XCTAssertEqual(executor.sent.first?.url, "https://api.anthropic.com/v1/messages")
    }

    func test_passesMethodAndBodyThrough() async {
        await send(handler(), method: "GET", uri: "/api/oauth/usage", body: [])
        XCTAssertEqual(executor.sent.first?.method, "GET")
        XCTAssertTrue(executor.sent.first?.body.isEmpty ?? false)
    }

    // MARK: 응답

    func test_relaysBufferedResponse() async {
        await send(handler())
        XCTAssertEqual(client.calls, [.head(status: 200), .write(8), .end])
    }

    /// 429 도 그대로 넘긴다. 스왑은 9단계다. 여기서 삼키면 클라이언트가 멈춘다.
    func test_relaysErrorStatusVerbatim() async {
        executor.reply = {
            .buffered(status: 429, headers: HeaderBag(),
                      body: Array(#"{"error":{"type":"rate_limit_error"}}"#.utf8), isSSE: false)
        }
        await send(handler())
        XCTAssertEqual(client.calls.first, .head(status: 429))
        XCTAssertTrue(client.bodyText.contains("rate_limit_error"))
    }

    func test_relaysStreamingResponse() async {
        executor.reply = {
            .streaming(status: 200, headers: HeaderBag(),
                       firstFrameBytes: Array("event: a\ndata: 1\n\n".utf8),
                       tail: [], rest: .empty)
        }
        await send(handler())
        XCTAssertEqual(client.bodyText, "event: a\ndata: 1\n\n")
        XCTAssertEqual(client.calls.last, .end)
    }

    // MARK: 실패

    /// 업스트림에 닿지 못한 것을 조용히 끝내면 Claude Code 가 빈 응답을 받는다.
    func test_upstreamFailureBecomesReadableError() async {
        struct Down: Error {}
        executor.reply = { throw Down() }
        await send(handler())

        guard case .head(let status) = client.calls.first else {
            return XCTFail("머리는 보내야 한다: \(client.calls)")
        }
        XCTAssertEqual(status, 502)
        XCTAssertTrue(client.bodyText.contains("clfl"), "누가 낸 오류인지 밝힌다")
        XCTAssertEqual(client.calls.last, .end)
    }

    func test_missingCredentialBecomesReadableError() async {
        let recorder = traces!
        let handler = SingleAccountHandler(
            account: acct(), tokens: StoredTokenProvider(store: InMemoryCredentialStore()),
            executor: executor, events: sink, trace: { recorder.record($0) })
        await send(handler)

        guard case .head(let status) = client.calls.first else { return XCTFail() }
        XCTAssertEqual(status, 502)
        XCTAssertTrue(executor.sent.isEmpty, "토큰이 없으면 업스트림을 부르지 않는다")
    }

    /// 첫 바이트가 이미 나갔으면 오류 본문을 덧쓸 수 없다. 끊는 수밖에 없다.
    func test_failureAfterFirstByteAbortsRatherThanWritingError() async {
        executor.reply = {
            let box = OneShotFailure()
            return .streaming(status: 200, headers: HeaderBag(),
                              firstFrameBytes: Array("event: a\ndata: 1\n\n".utf8),
                              tail: [], rest: UpstreamByteStream { try box.next() })
        }
        await send(handler())

        XCTAssertEqual(client.headCount, 1, "머리를 두 번 쓰지 않는다")
        XCTAssertTrue(client.calls.contains(.abort))
        XCTAssertFalse(client.calls.contains(.end))
    }

    // MARK: 사용량 기록

    func test_recordsUsageFromStream() async {
        let start = #"event: message_start"# + "\n"
            + #"data: {"message":{"usage":{"input_tokens":11,"cache_read_input_tokens":7}}}"#
            + "\n\n"
        let delta = #"event: message_delta"# + "\n"
            + #"data: {"usage":{"output_tokens":42}}"# + "\n\n"
        executor.reply = {
            .streaming(status: 200, headers: HeaderBag(),
                       firstFrameBytes: Array(start.utf8), tail: Array(delta.utf8),
                       rest: .empty)
        }

        var headers = HeaderBag()
        headers["x-claude-session-id"] = "sess-1"
        await send(handler(), headers: headers)

        let record = try? XCTUnwrap(sink.usage.first)
        XCTAssertEqual(record?.account, "team1")
        XCTAssertEqual(record?.inputTokens, 11)
        XCTAssertEqual(record?.outputTokens, 42)
        XCTAssertEqual(record?.cacheReadInputTokens, 7, "캐시 필드를 반드시 남긴다")
        XCTAssertEqual(record?.sessionID, "sess-1")
        XCTAssertEqual(record?.model, "x", "요청 body 의 model 을 그대로 쓴다")
    }

    /// usage 가 없는 응답까지 기록하면 0 짜리 줄만 쌓인다.
    func test_noUsageNoRecord() async {
        await send(handler())
        XCTAssertTrue(sink.usage.isEmpty)
    }
}

/// docs/design/08-verification.md 5절
final class SingleAccountTraceTests: XCTestCase {

    var executor: FakeExecutor!
    var traces: CapturingTraces!
    var client: RecordingClient!

    override func setUp() {
        executor = FakeExecutor()
        traces = CapturingTraces()
        client = RecordingClient()
    }

    func handler() -> SingleAccountHandler {
        let store = InMemoryCredentialStore()
        try? store.store(.longLived(token: "sk-ant-oat01-abc"), for: "team1")
        let recorder = traces!
        return SingleAccountHandler(
            account: acct(), tokens: StoredTokenProvider(store: store),
            executor: executor, events: NullEventSink(),
            trace: { recorder.record($0) })
    }

    func send(headers: HeaderBag = HeaderBag(),
              body: [UInt8] = Array(#"{"model":"claude-opus-4-5"}"#.utf8)) async {
        await handler().handle(method: "POST", uri: "/v1/messages",
                               headers: headers, body: body, client: client)
    }

    /// 요청마다 정확히 하나. 없으면 관측이 비고 둘이면 세는 것이 틀어진다.
    func test_oneTracePerRequest() async {
        await send()
        XCTAssertEqual(traces.items.count, 1)
    }

    func test_carriesModelSessionAndAccount() async {
        var headers = HeaderBag()
        headers["x-claude-session-id"] = "sess-9"
        await send(headers: headers)

        let trace = traces.items.first
        XCTAssertEqual(trace?.account, "team1")
        XCTAssertEqual(trace?.model, "claude-opus-4-5")
        XCTAssertEqual(trace?.sessionID, "sess-9")
        XCTAssertEqual(trace?.status, 200)
        XCTAssertEqual(trace?.outcome, .ok)
    }

    /// 세션 id 가 오는지가 8단계에서 확인할 항목이다.
    func test_recordsMissingSessionId() async {
        await send()
        XCTAssertNil(traces.items.first?.sessionID)
    }

    func test_countsRelayedBytes() async {
        executor.reply = {
            .streaming(status: 200, headers: HeaderBag(),
                       firstFrameBytes: Array("event: a\ndata: 1\n\n".utf8),
                       tail: Array("xy".utf8), rest: .empty)
        }
        await send()
        XCTAssertEqual(traces.items.first?.bytes, 20)
        XCTAssertTrue(traces.items.first?.isStreaming ?? false)
    }

    /// 클라이언트에 한 바이트도 안 나갔으면 스왑이 가능한 지점이다.
    func test_upstreamFailureIsFailedNotAborted() async {
        struct Down: Error {}
        executor.reply = { throw Down() }
        await send()

        guard case .failed(let reason) = traces.items.first?.outcome else {
            return XCTFail("failed 여야 한다: \(String(describing: traces.items.first?.outcome))")
        }
        XCTAssertTrue(reason.contains("업스트림"))
    }

    /// 첫 바이트가 나간 뒤 끊긴 것은 되돌릴 수 없다. 실패와 구분한다.
    func test_midStreamFailureIsAborted() async {
        executor.reply = {
            let box = OneShotFailure()
            return .streaming(status: 200, headers: HeaderBag(),
                              firstFrameBytes: Array("event: a\ndata: 1\n\n".utf8),
                              tail: [], rest: UpstreamByteStream { try box.next() })
        }
        await send()
        XCTAssertEqual(traces.items.first?.outcome, .aborted)
    }

    func test_credentialFailureIsRecorded() async {
        let recorder = traces!
        let handler = SingleAccountHandler(
            account: acct(), tokens: StoredTokenProvider(store: InMemoryCredentialStore()),
            executor: executor, events: NullEventSink(), trace: { recorder.record($0) })
        await handler.handle(method: "POST", uri: "/v1/messages",
                             headers: HeaderBag(), body: [], client: client)

        guard case .failed(let reason) = traces.items.first?.outcome else {
            return XCTFail("failed 여야 한다")
        }
        XCTAssertTrue(reason.contains("자격증명"))
        XCTAssertNil(traces.items.first?.status, "업스트림을 부르지도 않았다")
    }
}

/// 첫 next() 에서 끊긴다.
private final class OneShotFailure: @unchecked Sendable {
    struct Boom: Error {}
    func next() throws -> ByteBuffer? { throw Boom() }
}
