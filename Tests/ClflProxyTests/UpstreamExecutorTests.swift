import XCTest
import NIOCore
import ClflCore
@testable import ClflProxy

/// docs/design/04-implementation.md 1절, docs/porting/01-headers-and-auth.md 5절
final class UpstreamExecutorTests: XCTestCase {

    var upstream: RawUpstream!
    var executor: HTTPUpstreamExecutor!

    override func tearDown() async throws {
        upstream?.stop()
        upstream = nil
        await executor?.shutdown()
        executor = nil
    }

    /// 응답 바이트를 정하고 서버를 띄운다.
    func serve(_ chunks: [[UInt8]], gap: TimeAmount = .milliseconds(1)) throws {
        upstream = RawUpstream(chunks: chunks, gap: gap)
        try upstream.start()
        executor = HTTPUpstreamExecutor(connectTimeout: .milliseconds(500))
    }
    func serve(raw: String) throws { try serve([Array(raw.utf8)]) }

    func send(
        _ path: String = "/v1/messages",
        method: String = "POST",
        headers: HeaderBag = HeaderBag(),
        body: [UInt8] = Array(#"{"model":"claude-opus-4-5"}"#.utf8)
    ) async throws -> UpstreamAttempt {
        try await executor.execute(UpstreamRequest(
            url: "http://127.0.0.1:\(upstream.port)\(path)",
            method: method, headers: headers, body: body))
    }

    // MARK: 버퍼 응답

    func test_bufferedResponseCarriesStatusHeadersAndBody() async throws {
        try serve(raw: "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n"
                  + "content-length: 13\r\n\r\n{\"ok\":\"yes\"}\n")
        let attempt = try await send()

        guard case .buffered(let status, let headers, let body, let isSSE) = attempt else {
            return XCTFail("JSON 응답은 버퍼로 와야 한다")
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(headers["content-type"], "application/json")
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "{\"ok\":\"yes\"}\n")
        XCTAssertFalse(isSSE)
    }

    /// 429 는 실패가 아니라 시도 결과다. 던지면 분류기가 볼 기회를 잃는다.
    func test_errorStatusComesBackAsAttemptNotAsThrow() async throws {
        let body = Array(#"{"type":"error","error":{"type":"rate_limit_error"}}"#.utf8)
        try serve([RawUpstream.response(
            status: "429 Too Many Requests",
            headers: ["content-type: application/json", "retry-after: 42"],
            body: body)])

        let attempt = try await send()
        guard case .buffered(let status, let headers, let received, _) = attempt else {
            return XCTFail("버퍼 응답이어야 한다")
        }
        XCTAssertEqual(status, 429)
        XCTAssertEqual(headers["retry-after"], "42")

        let trigger = classifyResponse(ClassifyInput(
            status: status, headers: headers, body: Data(received),
            accountID: "team1", sessionID: "s", now: 1_700_000_000))
        guard case .rateLimit = trigger else { return XCTFail("rate_limit 로 분류돼야 한다") }
    }

    // MARK: 스트리밍

    func test_sseResponseIsStreamingNotBuffered() async throws {
        try serve([Array(("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n"
                          + "event: message_start\ndata: {}\n\n").utf8),
                   Array("event: content_block_delta\ndata: {\"i\":1}\n\n".utf8)])

        let attempt = try await send()
        guard case .streaming(let status, let headers, let first, _, _) = attempt else {
            return XCTFail("text/event-stream 은 스트리밍이어야 한다")
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(headers["content-type"], "text/event-stream")
        XCTAssertEqual(String(decoding: first, as: UTF8.self),
                       "event: message_start\ndata: {}\n\n",
                       "첫 프레임까지만 읽는다")
    }

    /// peek 의 존재 이유. 클라이언트에 한 바이트도 쓰기 전에 조직을 바꿀 수 있다.
    func test_streamingErrorFrameIsVisibleBeforeAnyRelay() async throws {
        try serve([Array(("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n"
                          + ": ping\n\n").utf8),
                   Array(GzipFixture.plain.utf8)])

        let attempt = try await send()
        guard case .streaming(_, let headers, let first, _, _) = attempt else {
            return XCTFail("스트리밍이어야 한다")
        }
        let event = try XCTUnwrap(parseFirstSSEEvent(first))
        XCTAssertEqual(event.event, "error", "선행 주석을 건너뛰고 error 프레임을 본다")

        let trigger = classifyResponse(ClassifyInput(
            status: 200, headers: headers, firstSSEEvent: event,
            accountID: "team1", sessionID: "s", now: 1_700_000_000))
        guard case .rateLimit = trigger else {
            return XCTFail("200 으로 시작한 스트림의 error 를 잡아야 한다")
        }
    }

    /// 경계를 못 본 채 닫힌 스트림. 성공으로 착각하면 빈 응답을 릴레이한다.
    func test_streamThatClosesWithoutAnyFrame() async throws {
        try serve([Array("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n".utf8)])
        let attempt = try await send()
        guard case .streaming(_, _, let first, _, _) = attempt else {
            return XCTFail("스트리밍이어야 한다")
        }
        XCTAssertTrue(first.isEmpty)
    }

    /// enum 을 고치며 생긴 계약. peek 뒤에도 스트림이 이어져야 릴레이가 성립한다.
    /// 여기가 비면 클라이언트는 첫 프레임만 받고 대화가 멈춘 것처럼 보인다.
    func test_remainderOfStreamIsReachableAfterPeek() async throws {
        let head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n"
        try serve([Array((head + "event: message_start\ndata: {}\n\n").utf8),
                   Array("event: delta\ndata: {\"i\":1}\n\n".utf8),
                   Array("event: message_stop\ndata: {}\n\n".utf8)])

        let attempt = try await send()
        guard case .streaming(_, _, let first, let tail, let rest) = attempt else {
            return XCTFail("스트리밍이어야 한다")
        }
        XCTAssertEqual(String(decoding: first, as: UTF8.self),
                       "event: message_start\ndata: {}\n\n")

        var remainder = tail
        while let chunk = try await rest.next() {
            remainder.append(contentsOf: chunk.readableBytesView)
        }
        XCTAssertEqual(String(decoding: remainder, as: UTF8.self),
                       "event: delta\ndata: {\"i\":1}\n\n"
                       + "event: message_stop\ndata: {}\n\n",
                       "peek 이 소비하지 않은 프레임이 전부 남아 있어야 한다")
    }

    /// 첫 프레임과 잔여를 이어붙이면 업스트림이 보낸 바이트와 정확히 같아야 한다.
    /// 한 바이트라도 새면 SSE 가 깨진다.
    func test_peekPlusRemainderEqualsOriginalStream() async throws {
        let head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n"
        let payload = ": ping\n\nevent: a\ndata: 1\n\nevent: b\ndata: 2\n\n"
        // 1바이트씩 흘려보내 최악의 청크 경계를 만든다
        var chunks: [[UInt8]] = [Array(head.utf8)]
        chunks += Array(payload.utf8).map { [$0] }
        try serve(chunks, gap: .microseconds(1))

        let attempt = try await send()
        guard case .streaming(_, _, let first, let tail, let rest) = attempt else {
            return XCTFail("스트리밍이어야 한다")
        }
        var all = first + tail
        while let chunk = try await rest.next() {
            all.append(contentsOf: chunk.readableBytesView)
        }
        XCTAssertEqual(String(decoding: all, as: UTF8.self), payload)
    }

    func test_closedEmptyStreamHasNoRemainder() async throws {
        try serve([Array("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n".utf8)])
        let attempt = try await send()
        guard case .streaming(_, _, _, _, let rest) = attempt else { return XCTFail() }
        let next = try await rest.next()
        XCTAssertNil(next)
    }

    // MARK: 압축 자동 해제

    /// 이 단계의 유일한 함정. 끄면 peek 이 gzip 바이트를 읽어 프레임 경계도
    /// error.type 도 찾지 못하고 스왑 판정 자체가 죽는다.
    func test_gzippedStreamArrivesDecompressed() async throws {
        try serve([Array("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n".utf8)
                   + Array("content-encoding: gzip\r\n".utf8)
                   + Array("content-length: \(GzipFixture.compressed.count)\r\n\r\n".utf8)
                   + GzipFixture.compressed])

        let attempt = try await send()
        guard case .streaming(_, _, let first, _, _) = attempt else {
            return XCTFail("스트리밍이어야 한다")
        }
        XCTAssertEqual(String(decoding: first, as: UTF8.self), GzipFixture.plain,
                       "gzip 바이트가 아니라 평문이 와야 한다")
    }

    func test_gzippedBufferedBodyArrivesDecompressed() async throws {
        try serve([Array("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n".utf8)
                   + Array("content-encoding: gzip\r\n".utf8)
                   + Array("content-length: \(GzipFixture.compressed.count)\r\n\r\n".utf8)
                   + GzipFixture.compressed])

        let attempt = try await send()
        guard case .buffered(_, _, let body, _) = attempt else {
            return XCTFail("버퍼여야 한다")
        }
        XCTAssertEqual(String(decoding: body, as: UTF8.self), GzipFixture.plain)
    }

    /// 본문을 풀어놓고 헤더에 gzip 이라고 적어 보내면 클라이언트가 해독에 실패한다.
    func test_contentEncodingIsStrippedOnceWeDecode() async throws {
        try serve([Array("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n".utf8)
                   + Array("content-encoding: gzip\r\n".utf8)
                   + Array("content-length: \(GzipFixture.compressed.count)\r\n\r\n".utf8)
                   + GzipFixture.compressed])

        let attempt = try await send()
        guard case .buffered(_, let headers, _, _) = attempt else { return XCTFail() }
        let forClient = ProxyHeaders.pickResponseHeaders(headers, clientDecodedBody: true)
        XCTAssertNil(forClient["content-encoding"])
        XCTAssertNil(forClient["content-length"], "프레이밍은 우리가 소유한다")
    }

    // MARK: 우리가 보내는 것

    func test_sendsMethodPathHeadersAndBody() async throws {
        try serve(raw: "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        var headers = HeaderBag()
        headers["anthropic-version"] = "2023-06-01"
        headers["x-custom"] = "kept"
        _ = try await send("/v1/messages?beta=true", method: "POST",
                           headers: headers, body: Array("hello".utf8))

        let request = try XCTUnwrap(upstream.requests.first)
        XCTAssertTrue(request.hasPrefix("POST /v1/messages?beta=true HTTP/1.1"),
                      "쿼리를 재인코딩하지 않는다:\n\(request)")
        XCTAssertTrue(request.lowercased().contains("anthropic-version: 2023-06-01"))
        XCTAssertTrue(request.lowercased().contains("x-custom: kept"))
        XCTAssertTrue(request.hasSuffix("hello"), "받은 원문:\n---\n\(request)\n---")
    }

    /// 우리가 풀 것이므로 업스트림에 압축을 요구한다. 요구하지 않으면 대역폭만 쓴다.
    func test_requestsCompressionFromUpstream() async throws {
        try serve(raw: "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        _ = try await send()
        let request = try XCTUnwrap(upstream.requests.first).lowercased()
        XCTAssertTrue(request.contains("accept-encoding"), "요청에 accept-encoding 이 있어야 한다")
    }

    /// GET 은 본문이 없다. content-length: 0 을 붙여 보내면 게이트웨이가 싫어한다.
    func test_getSendsNoBody() async throws {
        try serve(raw: "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        _ = try await send("/api/oauth/usage", method: "GET", body: [])
        let request = try XCTUnwrap(upstream.requests.first)
        XCTAssertTrue(request.hasPrefix("GET /api/oauth/usage HTTP/1.1"))
    }

    // MARK: 실패

    /// 붙지 못한 것은 시도 결과가 아니라 오류다. 이걸 200 처럼 다루면 안 된다.
    func test_connectionRefusedThrows() async throws {
        try serve(raw: "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        let deadPort = upstream.port
        upstream.stop()
        upstream = nil

        do {
            _ = try await executor.execute(UpstreamRequest(
                url: "http://127.0.0.1:\(deadPort)/v1/messages",
                method: "POST", headers: HeaderBag(), body: []))
            XCTFail("붙지 못하면 던져야 한다")
        } catch {
            // 기대한 경로
        }
    }

    /// 닿지 않는 조직이 요청을 오래 붙잡으면 스왑이 grace 예산을 넘긴다.
    /// AsyncHTTPClient 기본값 10초를 그대로 두면 조직 셋에 30초다.
    func test_connectTimeoutIsShortEnoughToSwapWithin() {
        XCTAssertLessThanOrEqual(HTTPUpstreamExecutor.defaultConnectTimeout,
                                 .seconds(5))
    }
}
