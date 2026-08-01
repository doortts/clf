import Foundation
import NIOCore
import ClflCore

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

/// 경계 판정 알고리즘은 ClflCore 의 findSSEBoundary 에 있다. 여기는 그것을 스트림에
/// 적용하는 루프뿐이다. 그래야 어려운 쪽(경계, 주석 건너뛰기, 청크 걸침)이 전부
/// 오프라인 테스트 대상이 된다.
///
/// Swift 의 AsyncIterator 는 들고 있다가 계속 next() 를 부르면 되는 값이라, Node 가
/// reader lock 때문에 스트림을 재조립하던 ~150줄이 통째로 사라진다.
public func peekFirstSSEFrame<I: AsyncIteratorProtocol>(
    _ iterator: inout I
) async throws -> PeekResult where I.Element == ByteBuffer {
    _ = iterator
    fatalError("TODO: 누적 -> findSSEBoundary -> 주석 프레임이면 건너뛰고 계속")
}
