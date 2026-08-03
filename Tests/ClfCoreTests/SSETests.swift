import XCTest
@testable import ClfCore

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

/// docs/porting/03-sse-streaming.md 10절
final class SSEBoundaryTests: XCTestCase {

    func test_case1_singleChunkFullFrame() {
        let bytes = b("event: message_start\ndata: {}\n\nevent: ping\n")
        let found = findSSEBoundary(bytes, from: 0)
        XCTAssertEqual(found?.length, 2)
        XCTAssertEqual(found?.index, b("event: message_start\ndata: {}").count)
    }

    /// 순진한 구현이 여기서 깨진다. 경계가 청크 사이에 걸린다.
    func test_case2_splitPacketBoundary() {
        let whole = b("data: {}\n\ndata: next\n\n")
        // 첫 조각에는 경계가 없다
        let first = Array(whole[0..<9])
        XCTAssertNil(findSSEBoundary(first, from: 0))
        // 최대 3바이트 되감고 다시 스캔하면 찾는다
        let resume = max(0, first.count - 3)
        XCTAssertEqual(findSSEBoundary(whole, from: resume)?.index, 8)
    }

    func test_case3_crlfNormalization() {
        let bytes = b("data: {}\r\n\r\nnext")
        let found = findSSEBoundary(bytes, from: 0)
        XCTAssertEqual(found?.length, 4)
        XCTAssertEqual(found?.index, b("data: {}").count)
    }

    func test_case3_lfWinsTieBreak() {
        // \n\n 이 \r\n\r\n 보다 앞서면 LF 매치가 이긴다
        XCTAssertEqual(findSSEBoundary(b("a\n\nb\r\n\r\n"), from: 0)?.length, 2)
    }

    /// 선행 주석 프레임은 건너뛰되 버리지 않는다.
    func test_case4_commentOnlyPrefix() {
        let bytes = b(":keepalive\n\n")
        let first = findSSEBoundary(bytes, from: 0)!
        XCTAssertTrue(isCommentOnlyFrame(bytes[0..<first.index]))
    }

    func test_case4_realEventFrameIsNotCommentOnly() {
        let bytes = b("event: error\ndata: {}\n\n")
        let first = findSSEBoundary(bytes, from: 0)!
        XCTAssertFalse(isCommentOnlyFrame(bytes[0..<first.index]))
    }

    func test_case4_mixedFrameWithCommentAndFieldIsNotCommentOnly() {
        XCTAssertFalse(isCommentOnlyFrame(ArraySlice(b(":note\ndata: {}"))))
    }

    func test_case5_closesBeforeAnyBoundary() {
        XCTAssertNil(findSSEBoundary(b("event: message_start\ndata: partial"), from: 0))
    }

    func test_case6_frameLargerThan8KiB() {
        let big = String(repeating: "x", count: 9000)
        let bytes = b("data: \(big)\n\n")
        XCTAssertEqual(findSSEBoundary(bytes, from: 0)?.index, b("data: \(big)").count)
    }

    /// 경계를 봤으므로 tail 은 빈 배열이 된다.
    func test_case7_streamEndsExactlyAfterFirstFrame() {
        let bytes = b("data: {}\n\n")
        let found = findSSEBoundary(bytes, from: 0)!
        XCTAssertEqual(found.index + found.length, bytes.count)
    }

    func test_tooShortInputReturnsNil() {
        XCTAssertNil(findSSEBoundary(b("\n"), from: 0))
        XCTAssertNil(findSSEBoundary([], from: 0))
    }
}

final class SSEParserTests: XCTestCase {

    func test_joinsMultipleDataLinesWithNewline() {
        var p = SSEParser()
        let out = p.push(b("event: x\ndata: one\ndata: two\n\n"))
        XCTAssertEqual(out, [SSEEvent(event: "x", data: "one\ntwo")])
    }

    func test_ignoresCommentLines() {
        var p = SSEParser()
        let out = p.push(b(":keepalive\ndata: hi\n\n"))
        XCTAssertEqual(out, [SSEEvent(event: "", data: "hi")])
    }

    /// 선행 공백은 딱 하나만 제거한다.
    func test_stripsExactlyOneLeadingSpaceFromValue() {
        var p = SSEParser()
        let out = p.push(b("data:  two-spaces\n\n"))
        XCTAssertEqual(out.first?.data, " two-spaces")
    }

    func test_emptyEventNameWhenFieldAbsent() {
        var p = SSEParser()
        XCTAssertEqual(p.push(b("data: {}\n\n")).first?.event, "")
    }

    func test_acceptsIdAndRetryWithoutSurfacing() {
        var p = SSEParser()
        let out = p.push(b("id: 7\nretry: 1000\ndata: hi\n\n"))
        XCTAssertEqual(out, [SSEEvent(event: "", data: "hi")])
    }

    func test_flushEmitsTrailingEventWithoutBlankLine() {
        var p = SSEParser()
        XCTAssertTrue(p.push(b("event: done\ndata: {}\n")).isEmpty)
        XCTAssertEqual(p.flush(), [SSEEvent(event: "done", data: "{}")])
    }

    func test_crlfLinesAreNormalized() {
        var p = SSEParser()
        XCTAssertEqual(p.push(b("event: x\r\ndata: y\r\n\r\n")),
                       [SSEEvent(event: "x", data: "y")])
    }

    func test_partialLineIsBufferedAcrossChunks() {
        var p = SSEParser()
        XCTAssertTrue(p.push(b("event: mes")).isEmpty)
        XCTAssertEqual(p.push(b("sage\ndata: {}\n\n")),
                       [SSEEvent(event: "message", data: "{}")])
    }

    /// Swift 전용. 줄을 바이트 단위로 잘라야 한국어와 이모지가 손상되지 않는다.
    func test_multibyteUTF8AcrossChunkBoundary() {
        let payload = "data: 한글과 이모지\n\n"
        let bytes = b(payload)
        // 멀티바이트 문자 한가운데에서 자른다
        let cut = 9
        var p = SSEParser()
        XCTAssertTrue(p.push(Array(bytes[0..<cut])).isEmpty)
        let out = p.push(Array(bytes[cut...]))
        XCTAssertEqual(out, [SSEEvent(event: "", data: "한글과 이모지")])
    }

    func test_parseFirstSSEEventReturnsOnlyFirst() {
        let ev = parseFirstSSEEvent(b("data: one\n\ndata: two\n\n"))
        XCTAssertEqual(ev, SSEEvent(event: "", data: "one"))
    }

    func test_parseFirstSSEEventNilWhenNoCompleteFrame() {
        XCTAssertNil(parseFirstSSEEvent(b("data: partial")))
    }
}

final class UsageSnifferTests: XCTestCase {

    /// 프레임 종단은 빈 줄이다. 헬퍼로 만들어 실수를 막는다.
    private func frame(_ event: String, _ data: String) -> [UInt8] {
        Array("event: \(event)\ndata: \(data)\n\n".utf8)
    }

    func test_collectsInputFromMessageStartAndOutputFromDelta() {
        var s = UsageSniffer()
        s.push(frame("message_start", #"{"type":"message_start","message":{"usage":"# +
            #"{"input_tokens":120,"cache_creation_input_tokens":30,"# +
            #""cache_read_input_tokens":900,"output_tokens":1}}}"#))
        s.push(frame("message_delta", #"{"type":"message_delta","usage":{"output_tokens":456}}"#))
        XCTAssertEqual(s.finish(), ParsedUsage(inputTokens: 120, outputTokens: 456,
                                               cacheCreationInputTokens: 30,
                                               cacheReadInputTokens: 900))
    }

    /// 종단 빈 줄 없이 스트림이 닫혀도 flush 가 마지막 프레임을 건진다.
    func test_collectsFromTrailingFrameWithoutBlankLine() {
        var s = UsageSniffer()
        s.push(Array(#"event: message_delta\#ndata: {"usage":{"output_tokens":7}}\#n"#.utf8))
        XCTAssertEqual(s.finish()?.outputTokens, 7)
    }

    func test_returnsNilWhenNoUsageSeen() {
        var s = UsageSniffer()
        s.push(frame("ping", "{}"))
        XCTAssertNil(s.finish())
    }

    func test_ignoresUnparseableFrames() {
        var s = UsageSniffer()
        s.push(frame("x", "not json"))
        XCTAssertNil(s.finish())
    }
}
