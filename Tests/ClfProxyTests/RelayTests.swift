import XCTest
import NIOCore
import ClfCore
@testable import ClfProxy

/// 클라이언트 소켓 대역. 호출 순서와 횟수를 그대로 기록한다.
///
/// 릴레이의 불변식은 전부 "무엇을 언제 몇 번 불렀나" 로 표현되므로
/// 기록만 정확하면 검증이 끝난다.
final class RecordingClient: ClientResponseWriting, @unchecked Sendable {
    enum Call: Equatable {
        case head(status: Int)
        case write(Int)         // 바이트 수
        case end
        case abort
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _body: [UInt8] = []
    private var _headers = HeaderBag()
    private var _alive = true
    /// 이 순번의 write 에서 클라이언트가 끊긴 것으로 만든다.
    var failWriteAt: Int?
    private var writeCount = 0

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    var body: [UInt8] { lock.lock(); defer { lock.unlock() }; return _body }
    var sentHeaders: HeaderBag { lock.lock(); defer { lock.unlock() }; return _headers }

    var headersSent: Bool {
        lock.lock(); defer { lock.unlock() }
        return _calls.contains { if case .head = $0 { return true }; return false }
    }
    var isAlive: Bool { lock.lock(); defer { lock.unlock() }; return _alive }
    func disconnect() { lock.lock(); _alive = false; lock.unlock() }

    func writeHead(status: Int, headers: HeaderBag) {
        lock.lock(); defer { lock.unlock() }
        // 프로토콜 계약. 재진입은 no-op
        guard !_calls.contains(where: { if case .head = $0 { return true }; return false })
        else { return }
        _calls.append(.head(status: status))
        _headers = headers
    }

    func write(_ bytes: [UInt8]) async throws {
        // async 함수 안에서는 NSLock 을 직접 잡을 수 없다. 동기 함수로 감싼다
        if try record(bytes) { return }
    }

    @discardableResult
    private func record(_ bytes: [UInt8]) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        writeCount += 1
        if writeCount == failWriteAt {
            _alive = false
            throw ProxyError.clientDisconnected
        }
        _calls.append(.write(bytes.count))
        _body.append(contentsOf: bytes)
        return true
    }

    func end()   { lock.lock(); _calls.append(.end);   lock.unlock() }
    func abort() { lock.lock(); _calls.append(.abort); lock.unlock() }

    var headCount: Int { calls.filter { if case .head = $0 { return true }; return false }.count }
    var bodyText: String { String(decoding: body, as: UTF8.self) }
}

/// 중간에 끊기는 업스트림.
private func stream(_ chunks: [String], failAfter: Int? = nil) -> UpstreamByteStream {
    let box = Counter(chunks: chunks, failAfter: failAfter)
    return UpstreamByteStream { try box.next() }
}
private final class Counter: @unchecked Sendable {
    var chunks: [String]
    let failAfter: Int?
    var served = 0
    init(chunks: [String], failAfter: Int?) { self.chunks = chunks; self.failAfter = failAfter }
    func next() throws -> ByteBuffer? {
        if let failAfter, served == failAfter { throw ProxyError.upstreamFailed(underlying: Boom()) }
        guard !chunks.isEmpty else { return nil }
        served += 1
        return ByteBuffer(string: chunks.removeFirst())
    }
}
private struct Boom: Error {}

private func bag(_ pairs: [String: String]) -> HeaderBag {
    var b = HeaderBag()
    for (k, v) in pairs { b[k] = v }
    return b
}

/// docs/porting/03-sse-streaming.md 7절, 8절
final class RelayTests: XCTestCase {

    // MARK: 버퍼 응답

    func test_bufferedWritesHeadBodyThenEnd() async throws {
        let client = RecordingClient()
        let attempt = UpstreamAttempt.buffered(
            status: 200, headers: bag(["content-type": "application/json"]),
            body: Array(#"{"ok":1}"#.utf8), isSSE: false)

        var sniffer = UsageSniffer()
        _ = try await relay(attempt, to: client, sniffer: &sniffer)

        XCTAssertEqual(client.calls, [.head(status: 200), .write(8), .end])
        XCTAssertEqual(client.bodyText, #"{"ok":1}"#)
    }

    func test_bufferedPreservesStatus() async throws {
        let client = RecordingClient()
        var sniffer = UsageSniffer()
        _ = try await relay(.buffered(status: 429, headers: HeaderBag(), body: [], isSSE: false),
                            to: client, sniffer: &sniffer)
        XCTAssertEqual(client.calls.first, .head(status: 429))
    }

    /// 본문을 풀어놓고 헤더에 gzip 이라고 적어 보내면 클라이언트가 해독에 실패한다.
    func test_stripsContentEncodingAndLength() async throws {
        let client = RecordingClient()
        var sniffer = UsageSniffer()
        _ = try await relay(.buffered(
            status: 200,
            headers: bag(["content-encoding": "gzip", "content-length": "999",
                          "transfer-encoding": "chunked", "content-type": "application/json"]),
            body: Array("hi".utf8), isSSE: false), to: client, sniffer: &sniffer)

        XCTAssertNil(client.sentHeaders["content-encoding"])
        XCTAssertNil(client.sentHeaders["content-length"], "프레이밍은 우리가 소유한다")
        XCTAssertNil(client.sentHeaders["transfer-encoding"])
        XCTAssertEqual(client.sentHeaders["content-type"], "application/json")
    }

    // MARK: 스트리밍

    /// 첫 프레임, tail, 나머지가 이 순서로 정확히 한 번씩 나가야 한다.
    func test_streamingWritesPeekedFrameThenTailThenRest() async throws {
        let client = RecordingClient()
        let attempt = UpstreamAttempt.streaming(
            status: 200, headers: bag(["content-type": "text/event-stream"]),
            firstFrameBytes: Array("event: a\ndata: 1\n\n".utf8),
            tail: Array("event: b\n".utf8),
            rest: stream(["data: 2\n\n", "event: c\ndata: 3\n\n"]))

        var sniffer = UsageSniffer()
        _ = try await relay(attempt, to: client, sniffer: &sniffer)

        XCTAssertEqual(client.bodyText,
                       "event: a\ndata: 1\n\nevent: b\ndata: 2\n\nevent: c\ndata: 3\n\n")
        XCTAssertEqual(client.calls.last, .end)
        XCTAssertEqual(client.headCount, 1)
    }

    /// 헤더가 나가기 전에 본문 한 바이트라도 쓰면 프로토콜이 깨진다.
    func test_headGoesOutBeforeAnyBody() async throws {
        let client = RecordingClient()
        var sniffer = UsageSniffer()
        _ = try await relay(.streaming(
            status: 200, headers: HeaderBag(),
            firstFrameBytes: Array("data: 1\n\n".utf8), tail: [],
            rest: stream(["data: 2\n\n"])), to: client, sniffer: &sniffer)

        guard case .head = client.calls.first else {
            return XCTFail("첫 호출이 writeHead 여야 한다: \(client.calls)")
        }
    }

    func test_writeHeadCalledExactlyOncePerResponse() async throws {
        let client = RecordingClient()
        var sniffer = UsageSniffer()
        _ = try await relay(.streaming(
            status: 200, headers: HeaderBag(),
            firstFrameBytes: Array("data: 1\n\n".utf8), tail: Array("x".utf8),
            rest: stream(["y", "z"])), to: client, sniffer: &sniffer)
        XCTAssertEqual(client.headCount, 1)
    }

    /// 빈 첫 프레임(경계 없이 닫힌 스트림)도 머리는 보내고 끝낸다.
    func test_emptyStreamStillSendsHeadAndEnds() async throws {
        let client = RecordingClient()
        var sniffer = UsageSniffer()
        _ = try await relay(.streaming(
            status: 200, headers: HeaderBag(), firstFrameBytes: [], tail: [],
            rest: .empty), to: client, sniffer: &sniffer)
        XCTAssertEqual(client.calls, [.head(status: 200), .end])
    }

    /// 빈 청크를 그대로 흘리면 쓰기 호출만 늘어난다.
    func test_doesNotWriteEmptyChunks() async throws {
        let client = RecordingClient()
        var sniffer = UsageSniffer()
        _ = try await relay(.streaming(
            status: 200, headers: HeaderBag(),
            firstFrameBytes: Array("data: 1\n\n".utf8), tail: [],
            rest: stream(["", "data: 2\n\n", ""])), to: client, sniffer: &sniffer)

        XCTAssertFalse(client.calls.contains(.write(0)))
    }

    // MARK: 중간 실패

    /// end() 를 부르면 chunked 종단자가 나가 잘린 스트림이 완결된 것처럼 보인다.
    /// Claude Code 에서 "Response stalled mid-stream" 으로 나타난다.
    func test_midStreamUpstreamFailureAbortsInsteadOfEnding() async throws {
        let client = RecordingClient()
        var sniffer = UsageSniffer()

        do {
            _ = try await relay(.streaming(
                status: 200, headers: HeaderBag(),
                firstFrameBytes: Array("data: 1\n\n".utf8), tail: [],
                rest: stream(["data: 2\n\n"], failAfter: 1)), to: client, sniffer: &sniffer)
            XCTFail("업스트림이 끊기면 던져야 한다")
        } catch {
            // 기대한 경로
        }

        XCTAssertTrue(client.calls.contains(.abort))
        XCTAssertFalse(client.calls.contains(.end), "end 는 완결을 뜻한다")
    }

    /// 첫 프레임을 쓰기도 전에 실패하면 아직 아무것도 안 나갔으므로
    /// 스왑 루프가 다른 조직으로 넘어갈 수 있다. abort 도 부르지 않는다.
    func test_failureBeforeFirstByteLeavesClientUntouched() async throws {
        let client = RecordingClient()
        client.failWriteAt = 1
        var sniffer = UsageSniffer()

        _ = try? await relay(.streaming(
            status: 200, headers: HeaderBag(),
            firstFrameBytes: Array("data: 1\n\n".utf8), tail: [],
            rest: .empty), to: client, sniffer: &sniffer)

        XCTAssertFalse(client.calls.contains(.end))
    }

    /// 클라이언트가 먼저 끊으면 업스트림을 계속 당길 이유가 없다.
    func test_stopsPullingUpstreamAfterClientDisconnects() async throws {
        let client = RecordingClient()
        let counter = Counter(chunks: ["a", "b", "c", "d"], failAfter: nil)
        let rest = UpstreamByteStream { try counter.next() }
        var sniffer = UsageSniffer()

        client.failWriteAt = 2      // 첫 프레임은 나가고 두 번째 쓰기에서 끊긴다
        _ = try? await relay(.streaming(
            status: 200, headers: HeaderBag(),
            firstFrameBytes: Array("data: 1\n\n".utf8), tail: [], rest: rest),
            to: client, sniffer: &sniffer)

        XCTAssertLessThanOrEqual(counter.served, 2,
                                 "끊긴 뒤에도 남은 청크를 전부 당기면 안 된다")
    }

    // MARK: 사용량

    /// 릴레이하며 지나가는 바이트에서 줍는다. 요청을 하나 더 보내지 않는다.
    func test_sniffsUsageFromRelayedStream() async throws {
        let client = RecordingClient()
        let start = #"event: message_start"# + "\n"
            + #"data: {"message":{"usage":{"input_tokens":11,"cache_read_input_tokens":7}}}"#
            + "\n\n"
        let delta = #"event: message_delta"# + "\n"
            + #"data: {"usage":{"output_tokens":42}}"# + "\n\n"

        var sniffer = UsageSniffer()
        let usage = try await relay(.streaming(
            status: 200, headers: HeaderBag(),
            firstFrameBytes: Array(start.utf8), tail: [],
            rest: stream([delta])), to: client, sniffer: &sniffer)

        XCTAssertEqual(usage, ParsedUsage(inputTokens: 11, outputTokens: 42,
                                          cacheCreationInputTokens: 0,
                                          cacheReadInputTokens: 7))
    }

    /// 스니퍼가 바이트를 소비만 하고 바꾸지 않는다.
    func test_snifferDoesNotAlterRelayedBytes() async throws {
        let client = RecordingClient()
        let payload = "event: message_start\ndata: {\"message\":{\"usage\":{\"input_tokens\":1}}}\n\n"
        var sniffer = UsageSniffer()
        _ = try await relay(.streaming(
            status: 200, headers: HeaderBag(),
            firstFrameBytes: Array(payload.utf8), tail: [], rest: .empty),
            to: client, sniffer: &sniffer)
        XCTAssertEqual(client.bodyText, payload)
    }

    func test_bufferedNonSSEYieldsNoUsage() async throws {
        let client = RecordingClient()
        var sniffer = UsageSniffer()
        let usage = try await relay(.buffered(
            status: 200, headers: HeaderBag(),
            body: Array(#"{"usage":{"output_tokens":5}}"#.utf8), isSSE: false),
            to: client, sniffer: &sniffer)
        XCTAssertNil(usage, "SSE 가 아니면 스니퍼를 태우지 않는다")
    }

    /// 릴레이 중 event: error 가 와도 재분류하지 않고 원문을 전달한다.
    /// 바이트가 소켓을 건넌 뒤에는 조직을 바꿀 수 없다.
    func test_errorFrameMidStreamIsRelayedVerbatim() async throws {
        let client = RecordingClient()
        let payload = "event: error\ndata: {\"error\":{\"type\":\"rate_limit_error\"}}\n\n"
        var sniffer = UsageSniffer()
        _ = try await relay(.streaming(
            status: 200, headers: HeaderBag(),
            firstFrameBytes: Array("event: message_start\ndata: {}\n\n".utf8), tail: [],
            rest: stream([payload])), to: client, sniffer: &sniffer)

        XCTAssertTrue(client.bodyText.hasSuffix(payload))
        XCTAssertEqual(client.calls.last, .end, "중간 error 는 정상 종료다")
    }
}
