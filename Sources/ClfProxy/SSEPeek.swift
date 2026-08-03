import Foundation
import NIOCore
import ClfCore

/// docs/porting/03-sse-streaming.md 4절
public struct PeekResult: Sendable {
    /// 스트림 시작부터 첫 "이벤트를 담은" 프레임 종단까지. 선행 주석 프레임 포함.
    public let firstFrameBytes: [UInt8]
    /// 경계 이후 이미 읽어둔 잔여. 릴레이 시 이걸 먼저 내보낸 뒤 iterator 를 계속 돈다.
    public let tail: [UInt8]
    /// 경계를 한 번도 보지 못한 채 업스트림이 닫혔으면 true.
    public let closedEmpty: Bool

    public init(firstFrameBytes: [UInt8], tail: [UInt8], closedEmpty: Bool) {
        self.firstFrameBytes = firstFrameBytes
        self.tail = tail
        self.closedEmpty = closedEmpty
    }
}

/// 경계 판정 알고리즘은 ClfCore 의 findSSEBoundary 에 있다. 여기는 그것을 스트림에
/// 적용하는 루프뿐이다. 그래야 어려운 쪽(경계, 주석 건너뛰기, 청크 걸침)이 전부
/// 오프라인 테스트 대상이 된다.
///
/// Swift 의 AsyncIterator 는 들고 있다가 계속 next() 를 부르면 되는 값이라, Node 가
/// reader lock 때문에 스트림을 재조립하던 ~150줄이 통째로 사라진다.
public func peekFirstSSEFrame<I: AsyncIteratorProtocol>(
    _ iterator: inout I
) async throws -> PeekResult where I.Element == ByteBuffer {
    var buf: [UInt8] = []
    var frameStart = 0      // 건너뛴 주석 프레임 다음 위치
    var searchFrom = 0      // 증분 스캔 시작점

    while let chunk = try await iterator.next() {
        buf.append(contentsOf: chunk.readableBytesView)

        while true {
            guard let boundary = findSSEBoundary(buf, from: searchFrom) else {
                // 종단이 청크 사이에 걸칠 수 있다. 가장 긴 것이 4바이트(\r\n\r\n)이므로
                // 3바이트를 되감으면 다음 청크와 이어 붙였을 때 반드시 다시 만난다.
                searchFrom = max(searchFrom, max(0, buf.count - 3))
                break
            }
            let endOfFrame = boundary.index + boundary.length

            // 주석 전용 프레임에서 멈추면 분류기가 error.type 대신 빈 문자열을 본다.
            // 건너뛰되 바이트는 버리지 않는다. 릴레이할 때 그대로 나가야 한다.
            if isCommentOnlyFrame(buf[frameStart..<boundary.index]) {
                frameStart = endOfFrame
                searchFrom = endOfFrame
                continue
            }

            return PeekResult(
                firstFrameBytes: Array(buf[0..<endOfFrame]),
                tail: Array(buf[endOfFrame...]),
                closedEmpty: false)
        }
    }

    // 이벤트 프레임을 한 번도 보지 못한 채 업스트림이 닫혔다.
    return PeekResult(firstFrameBytes: buf, tail: [], closedEmpty: true)
}

/// 스캐폴딩 자리 표시. fatalError 를 쓰면 테스트 프로세스가 통째로 죽어
/// 어느 것이 빨간지 볼 수 없다.
public struct NotImplemented: Error, CustomStringConvertible {
    public let what: String
    public var description: String { "\(what) 미구현" }
}
