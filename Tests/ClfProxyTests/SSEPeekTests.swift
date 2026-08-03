import XCTest
import NIOCore
import ClfCore
@testable import ClfProxy

/// 청크 경계를 우리가 정하는 가짜 업스트림.
///
/// 실제 네트워크는 청크를 어디서 자를지 고르게 해주지 않는다. 경계가 걸치는
/// 경우가 정확히 여기서 깨지므로 자르는 위치를 테스트가 쥔다.
struct ChunkedSource: AsyncSequence {
    typealias Element = ByteBuffer
    let chunks: [[UInt8]]

    init(_ chunks: [[UInt8]]) { self.chunks = chunks }
    init(strings: [String]) { self.chunks = strings.map { Array($0.utf8) } }

    struct Iterator: AsyncIteratorProtocol {
        var remaining: [[UInt8]]
        mutating func next() async throws -> ByteBuffer? {
            guard !remaining.isEmpty else { return nil }
            return ByteBuffer(bytes: remaining.removeFirst())
        }
    }
    func makeAsyncIterator() -> Iterator { Iterator(remaining: chunks) }
}

private func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

/// docs/porting/03-sse-streaming.md 4절
final class SSEPeekTests: XCTestCase {

    func peek(_ chunks: [String]) async throws -> (PeekResult, ChunkedSource.Iterator) {
        var iterator = ChunkedSource(strings: chunks).makeAsyncIterator()
        let result = try await peekFirstSSEFrame(&iterator)
        return (result, iterator)
    }

    // MARK: 기본

    func test_singleChunkWithOneCompleteFrame() async throws {
        let (r, _) = try await peek(["event: message_start\ndata: {}\n\n"])
        XCTAssertEqual(text(r.firstFrameBytes), "event: message_start\ndata: {}\n\n")
        XCTAssertTrue(r.tail.isEmpty)
        XCTAssertFalse(r.closedEmpty)
    }

    /// 경계 이후 이미 읽어둔 바이트를 잃으면 릴레이가 첫 델타를 통째로 빠뜨린다.
    func test_bytesAfterBoundaryBecomeTail() async throws {
        let (r, _) = try await peek(["event: a\ndata: 1\n\nevent: b\ndata: 2\n\n"])
        XCTAssertEqual(text(r.firstFrameBytes), "event: a\ndata: 1\n\n")
        XCTAssertEqual(text(r.tail), "event: b\ndata: 2\n\n")
    }

    func test_frameSplitAcrossChunks() async throws {
        let (r, _) = try await peek(["event: message", "_start\ndata: {}", "\n\nrest"])
        XCTAssertEqual(text(r.firstFrameBytes), "event: message_start\ndata: {}\n\n")
        XCTAssertEqual(text(r.tail), "rest")
    }

    // MARK: 경계가 청크 사이에 걸친다

    /// LF LF 가 서로 다른 청크로 갈린다. 증분 스캔이 되감지 않으면 영영 못 찾는다.
    func test_lfBoundarySplitAcrossChunks() async throws {
        let (r, _) = try await peek(["data: 1\n", "\ntail"])
        XCTAssertEqual(text(r.firstFrameBytes), "data: 1\n\n")
        XCTAssertEqual(text(r.tail), "tail")
    }

    /// CRLF 종단 4바이트가 최악의 위치에서 갈린다. 3바이트 되감기의 근거다.
    func test_crlfBoundarySplitAtWorstPosition() async throws {
        let bytes = Array("data: 1\r\n\r\ntail".utf8)
        let boundaryStart = 7                        // \r\n\r\n 이 시작하는 위치
        for split in 1...3 {
            let cut = boundaryStart + split          // 종단 4바이트 안쪽에서 자른다
            let (r, _) = try await peek([text(Array(bytes[0..<cut])),
                                         text(Array(bytes[cut...]))])
            XCTAssertEqual(text(r.firstFrameBytes), "data: 1\r\n\r\n", "split=\(split)")
            XCTAssertEqual(text(r.tail), "tail", "split=\(split)")
        }
    }

    /// 경계를 만나면 즉시 멈춘다. 한 청크도 더 당기지 않는다.
    ///
    /// 1바이트씩 오면 경계를 완성한 청크가 마지막으로 읽은 것이므로 tail 이 비고
    /// 나머지는 iterator 에 남는다. 미리 읽어두면 그만큼 첫 바이트가 늦는다.
    func test_oneBytePerChunkStopsAtBoundaryWithoutReadingAhead() async throws {
        let (r, initial) = try await peek("event: a\ndata: 1\n\nz".map(String.init))
        var iterator = initial
        XCTAssertEqual(text(r.firstFrameBytes), "event: a\ndata: 1\n\n")
        XCTAssertTrue(r.tail.isEmpty, "경계에서 끝난 청크라 남는 바이트가 없다")

        let next = try await iterator.next()
        XCTAssertEqual(text(Array(next!.readableBytesView)), "z", "z 는 아직 스트림에 있다")
    }

    // MARK: 주석 프레임

    /// 주석 프레임에서 멈추면 분류기가 error.type 대신 빈 문자열을 본다.
    func test_skipsLeadingCommentFrame() async throws {
        let (r, _) = try await peek([": ping\n\nevent: a\ndata: 1\n\n"])
        XCTAssertEqual(text(r.firstFrameBytes), ": ping\n\nevent: a\ndata: 1\n\n",
                       "건너뛴 주석도 릴레이해야 하므로 반환값에 포함된다")
        XCTAssertTrue(r.tail.isEmpty)
    }

    func test_skipsSeveralCommentFrames() async throws {
        let (r, _) = try await peek([": a\n\n", ": b\n\n", ": c\n\n", "data: real\n\ntail"])
        XCTAssertEqual(text(r.firstFrameBytes), ": a\n\n: b\n\n: c\n\ndata: real\n\n")
        XCTAssertEqual(text(r.tail), "tail")
    }

    func test_commentFrameSplitAcrossChunks() async throws {
        let (r, _) = try await peek([": pi", "ng\n", "\ndata: real\n\n"])
        XCTAssertEqual(text(r.firstFrameBytes), ": ping\n\ndata: real\n\n")
    }

    /// 주석 줄과 데이터 줄이 한 프레임에 섞이면 주석 전용이 아니다.
    func test_frameWithCommentAndDataIsNotCommentOnly() async throws {
        let (r, _) = try await peek([": note\ndata: 1\n\ntail"])
        XCTAssertEqual(text(r.firstFrameBytes), ": note\ndata: 1\n\n")
        XCTAssertEqual(text(r.tail), "tail")
    }

    // MARK: 종료

    /// 경계를 못 본 채 닫혔다. 호출자가 이걸 성공으로 착각하면 빈 응답을 릴레이한다.
    func test_closedWithoutBoundary() async throws {
        let (r, _) = try await peek(["data: never terminated"])
        XCTAssertTrue(r.closedEmpty)
        XCTAssertEqual(text(r.firstFrameBytes), "data: never terminated")
        XCTAssertTrue(r.tail.isEmpty)
    }

    func test_emptyStream() async throws {
        let (r, _) = try await peek([])
        XCTAssertTrue(r.closedEmpty)
        XCTAssertTrue(r.firstFrameBytes.isEmpty)
    }

    /// 주석만 흘리다 닫혔다. 이벤트 프레임이 없으므로 소진으로 본다.
    func test_onlyCommentFramesThenClose() async throws {
        let (r, _) = try await peek([": ping\n\n: ping\n\n"])
        XCTAssertTrue(r.closedEmpty)
        XCTAssertEqual(text(r.firstFrameBytes), ": ping\n\n: ping\n\n",
                       "릴레이할 수 있도록 읽은 바이트는 전부 돌려준다")
    }

    // MARK: iterator 를 이어서 쓴다

    /// Node 가 스트림을 재조립하느라 70줄을 쓴 자리다. Swift 는 같은 iterator 를
    /// 계속 돌리면 된다. 그 성질이 실제로 성립하는지 잠근다.
    func test_iteratorContinuesAfterPeek() async throws {
        let (r, initial) = try await peek(["data: 1\n\nA", "B", "C"])
        var iterator = initial
        XCTAssertEqual(text(r.tail), "A")

        var rest: [UInt8] = []
        while let chunk = try await iterator.next() {
            rest.append(contentsOf: chunk.readableBytesView)
        }
        XCTAssertEqual(text(rest), "BC", "peek 이 소비하지 않은 청크가 그대로 남는다")
    }

    // MARK: 바이트 보존

    /// 청크 경계에 멀티바이트 UTF-8 이 걸려도 바이트를 건드리지 않는다.
    /// 문자열로 변환하며 자르면 대체 문자가 생긴다.
    func test_multibyteSplitAcrossChunksSurvives() async throws {
        let full = Array("data: 한글과 이모지 \u{1F600}\n\n".utf8)
        let cut = 13                                  // "과" 3바이트 한가운데
        var iterator = ChunkedSource([Array(full[0..<cut]), Array(full[cut...])])
            .makeAsyncIterator()
        let r = try await peekFirstSSEFrame(&iterator)
        XCTAssertEqual(r.firstFrameBytes, full)
        XCTAssertEqual(text(r.firstFrameBytes), "data: 한글과 이모지 \u{1F600}\n\n")
    }

    /// peek 자체는 상한을 두지 않는다. 크기 제한은 호출자의 관심사다.
    func test_noSizeLimitOnFirstFrame() async throws {
        let big = String(repeating: "x", count: 2_000_000)
        let (r, _) = try await peek(["data: \(big)\n\n"])
        XCTAssertEqual(r.firstFrameBytes.count, 2_000_008)
        XCTAssertFalse(r.closedEmpty)
    }

    // MARK: 분류기로 이어진다

    /// peek 의 존재 이유. 첫 프레임이 error 면 클라이언트에 한 바이트도 쓰기 전에
    /// 조직을 바꿀 수 있다.
    func test_peekedFrameFeedsClassifier() async throws {
        let (r, _) = try await peek([
            ": ping\n\n",
            #"event: error"# + "\n"
            + #"data: {"type":"error","error":{"type":"rate_limit_error"}}"# + "\n\n",
        ])
        let event = try XCTUnwrap(parseFirstSSEEvent(r.firstFrameBytes))
        XCTAssertEqual(event.event, "error")

        let trigger = classifyResponse(ClassifyInput(
            status: 200, headers: HeaderBag(), firstSSEEvent: event,
            accountID: "team1", sessionID: "s", now: 1_700_000_000))
        guard case .rateLimit = trigger else {
            return XCTFail("200 으로 시작한 스트림의 error 프레임을 잡아야 한다")
        }
    }
}
