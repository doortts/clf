import XCTest
import NIOCore
import AsyncHTTPClient
import ClfCore
@testable import ClfProxy

/// 테스트가 응답을 정하는 핸들러. 서버가 무엇을 받았는지도 기록한다.
final class ScriptedHandler: RequestHandling, @unchecked Sendable {
    struct Seen: Sendable {
        var method = ""
        var uri = ""
        var headers = HeaderBag()
        var body: [UInt8] = []
    }

    private let lock = NSLock()
    private var _seen: [Seen] = []
    var seen: [Seen] { lock.lock(); defer { lock.unlock() }; return _seen }

    /// 요청을 받은 뒤 무엇을 쓸지. 기본은 200 JSON.
    var respond: @Sendable (any ClientResponseWriting) async -> Void = { client in
        client.writeHead(status: 200, headers: HeaderBag())
        try? await client.write(Array(#"{"ok":1}"#.utf8))
        client.end()
    }

    func handle(method: String, uri: String, headers: HeaderBag, body: [UInt8],
                client: any ClientResponseWriting) async {
        // async 함수 안에서는 NSLock 을 직접 잡을 수 없다
        record(Seen(method: method, uri: uri, headers: headers, body: body))
        await respond(client)
    }

    private func record(_ seen: Seen) {
        lock.lock(); defer { lock.unlock() }
        _seen.append(seen)
    }
}

/// docs/design/04-implementation.md 1절
final class ProxyServerTests: XCTestCase {

    var server: ProxyServer!
    var handler: ScriptedHandler!
    var client: HTTPClient!
    var port: UInt16 = 0

    override func setUp() async throws {
        handler = ScriptedHandler()
        server = ProxyServer(handler: handler)
        port = try await server.start(port: 0)
        client = HTTPClient(eventLoopGroupProvider: .singleton)
    }

    override func tearDown() async throws {
        try? await client?.shutdown()
        client = nil
        await server?.shutdown()
        server = nil
        handler = nil
    }

    func get(_ path: String = "/v1/messages",
             method: String = "POST",
             headers: [(String, String)] = [],
             body: String? = nil) async throws -> HTTPClientResponse {
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)\(path)")
        request.method = .init(rawValue: method)
        for (k, v) in headers { request.headers.add(name: k, value: v) }
        if let body { request.body = .bytes(ByteBuffer(string: body)) }
        return try await client.execute(request, timeout: .seconds(10))
    }

    // MARK: 바인딩

    /// 요청 포트가 점유돼 있으면 다음 빈 포트로 폴백하므로 호출자는 반환값으로
    /// settings.json 을 갱신해야 한다. 바인딩 자체가 단일 인스턴스 락이다.
    func test_startReturnsTheActualBoundPort() {
        XCTAssertGreaterThan(port, 0)
    }

    func test_shutdownReleasesThePort() async throws {
        let released = port
        await server.shutdown()
        server = nil

        // 같은 포트를 다시 잡을 수 있어야 한다
        let second = ProxyServer(handler: ScriptedHandler())
        let bound = try await second.start(port: released)
        XCTAssertEqual(bound, released)
        await second.shutdown()
    }

    // MARK: 왕복

    func test_roundTripsABufferedResponse() async throws {
        let response = try await get(body: #"{"model":"x"}"#)
        XCTAssertEqual(response.status.code, 200)
        let body = try await response.body.collect(upTo: 1 << 20)
        XCTAssertEqual(String(buffer: body), #"{"ok":1}"#)
    }

    /// 프록시가 요청을 그대로 넘겨야 업스트림이 같은 답을 낸다.
    func test_handlerSeesMethodUriHeadersAndBody() async throws {
        _ = try await get("/v1/messages?beta=true", method: "POST",
                          headers: [("x-custom", "kept"), ("anthropic-version", "2023-06-01")],
                          body: "hello")

        let seen = try XCTUnwrap(handler.seen.first)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.uri, "/v1/messages?beta=true", "쿼리를 재인코딩하지 않는다")
        XCTAssertEqual(seen.headers["x-custom"], "kept")
        XCTAssertEqual(seen.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(String(decoding: seen.body, as: UTF8.self), "hello")
    }

    func test_bodyArrivingInSeveralChunksIsReassembled() async throws {
        let big = String(repeating: "a", count: 300_000)
        _ = try await get(body: big)
        XCTAssertEqual(handler.seen.first?.body.count, 300_000)
    }

    func test_getWithoutBody() async throws {
        _ = try await get("/api/oauth/usage", method: "GET")
        XCTAssertEqual(handler.seen.first?.method, "GET")
        XCTAssertTrue(handler.seen.first?.body.isEmpty ?? false)
    }

    func test_passesErrorStatusThrough() async throws {
        handler.respond = { client in
            client.writeHead(status: 429, headers: HeaderBag())
            try? await client.write(Array(#"{"error":1}"#.utf8))
            client.end()
        }
        let response = try await get()
        XCTAssertEqual(response.status.code, 429)
    }

    func test_responseHeadersReachTheClient() async throws {
        handler.respond = { client in
            var headers = HeaderBag()
            headers["content-type"] = "text/event-stream"
            headers["anthropic-ratelimit-unified-5h-remaining"] = "63"
            client.writeHead(status: 200, headers: headers)
            client.end()
        }
        let response = try await get()
        XCTAssertEqual(response.headers.first(name: "content-type"), "text/event-stream")
        XCTAssertEqual(response.headers.first(name: "anthropic-ratelimit-unified-5h-remaining"),
                       "63")
    }

    // MARK: 스트리밍

    /// 프레임이 하나씩 도착해야 한다. 전부 모아 한 번에 주면 SSE 가 아니다.
    func test_streamsFramesIncrementally() async throws {
        handler.respond = { client in
            var headers = HeaderBag()
            headers["content-type"] = "text/event-stream"
            client.writeHead(status: 200, headers: headers)
            for i in 1...3 {
                try? await client.write(Array("event: d\ndata: \(i)\n\n".utf8))
                try? await Task.sleep(for: .milliseconds(20))
            }
            client.end()
        }

        let response = try await get()
        var frames = 0
        var text = ""
        for try await chunk in response.body {
            text += String(buffer: chunk)
            frames += 1
        }
        XCTAssertEqual(text, "event: d\ndata: 1\n\nevent: d\ndata: 2\n\nevent: d\ndata: 3\n\n")
        XCTAssertGreaterThan(frames, 1, "한 덩어리로 오면 스트리밍이 아니다")
    }

    /// abort 는 종단자를 보내지 않는다. 클라이언트가 잘린 것을 알아야 한다.
    func test_abortDoesNotLookLikeACleanEnd() async throws {
        handler.respond = { client in
            var headers = HeaderBag()
            headers["content-type"] = "text/event-stream"
            client.writeHead(status: 200, headers: headers)
            try? await client.write(Array("event: a\ndata: 1\n\n".utf8))
            client.abort()
        }

        do {
            let response = try await get()
            var text = ""
            for try await chunk in response.body { text += String(buffer: chunk) }
            XCTFail("잘린 스트림을 완결로 받으면 안 된다. 받은 것: \(text)")
        } catch {
            // 기대한 경로. 클라이언트가 불완전한 본문으로 실패한다
        }
    }

    // MARK: 릴레이와 붙인다

    /// 8단계의 실질. 업스트림 응답이 프록시를 지나 클라이언트까지 바이트 그대로 간다.
    func test_relayCarriesUpstreamStreamToClientVerbatim() async throws {
        let payload = ": ping\n\nevent: message_start\ndata: {}\n\n"
            + "event: message_stop\ndata: {}\n\n"
        handler.respond = { client in
            var upstreamHeaders = HeaderBag()
            upstreamHeaders["content-type"] = "text/event-stream"
            upstreamHeaders["content-encoding"] = "gzip"     // 우리가 이미 풀었다
            upstreamHeaders["content-length"] = "999"        // 프레이밍은 우리가 소유

            var iterator = ChunkedSource(strings: [payload]).makeAsyncIterator()
            let peeked = try! await peekFirstSSEFrame(&iterator)
            var sniffer = UsageSniffer()
            _ = try? await relay(.streaming(
                status: 200, headers: upstreamHeaders,
                firstFrameBytes: peeked.firstFrameBytes, tail: peeked.tail,
                rest: .wrapping(iterator)), to: client, sniffer: &sniffer)
        }

        let response = try await get()
        let body = try await response.body.collect(upTo: 1 << 20)
        XCTAssertEqual(String(buffer: body), payload)
        XCTAssertNil(response.headers.first(name: "content-encoding"),
                     "풀어놓고 gzip 이라 적으면 클라이언트가 해독에 실패한다")
    }
}
