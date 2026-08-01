import XCTest
@testable import ClflCore

/// docs/porting/03-sse-streaming.md 10절
final class SSEBoundaryTests: XCTestCase {
    func test_case1_singleChunkFullFrame() throws { throw XCTSkip("미구현") }

    /// 순진한 구현이 여기서 깨진다.
    func test_case2_splitPacketBoundary() throws { throw XCTSkip("미구현") }
    func test_case3_crlfNormalization() throws { throw XCTSkip("미구현") }

    /// 선행 주석 프레임은 건너뛰되 버리지 않는다. firstFrameBytes 에 포함한다.
    func test_case4_commentOnlyPrefix() throws { throw XCTSkip("미구현") }

    func test_case5_closesBeforeAnyBoundary() throws { throw XCTSkip("미구현") }
    func test_case6_frameLargerThan8KiB() throws { throw XCTSkip("미구현") }

    /// 경계를 봤으므로 closedEmpty 는 false, tail 은 빈 배열.
    func test_case7_streamEndsExactlyAfterFirstFrame() throws { throw XCTSkip("미구현") }
}

final class SSEParserTests: XCTestCase {
    func test_joinsMultipleDataLinesWithNewline() throws { throw XCTSkip("미구현") }
    func test_ignoresCommentLines() throws { throw XCTSkip("미구현") }
    func test_stripsExactlyOneLeadingSpaceFromValue() throws { throw XCTSkip("미구현") }
    func test_emptyEventNameWhenFieldAbsent() throws { throw XCTSkip("미구현") }
    func test_acceptsIdAndRetryWithoutSurfacing() throws { throw XCTSkip("미구현") }
    func test_flushEmitsTrailingEventWithoutBlankLine() throws { throw XCTSkip("미구현") }

    /// Swift 전용. 줄을 바이트 단위로 잘라야 한국어와 이모지가 손상되지 않는다.
    func test_multibyteUTF8AcrossChunkBoundary() throws { throw XCTSkip("미구현") }
}
