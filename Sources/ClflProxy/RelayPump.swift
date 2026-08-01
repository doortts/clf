import Foundation
import NIOCore
import ClflCore

/// 클라이언트 쓰기 표면. 테스트가 가짜 객체로 writeHead 호출 횟수와 시점을
/// 검증할 수 있게 프로토콜로 둔다.
public protocol ClientResponseWriting: AnyObject, Sendable {
    var headersSent: Bool { get }
    var isAlive: Bool { get }
    func writeHead(status: Int, headers: HeaderBag)
    /// await 자체가 backpressure 다. 이전 쓰기가 끝나야 다음 청크를 당겨온다.
    func write(_ bytes: [UInt8]) async throws
    func end()
    /// 중간 실패 전용. end() 를 부르면 chunked 종단자가 나가 잘린 스트림이 완결된
    /// 것처럼 보인다. Claude Code 에서 "Response stalled mid-stream" 으로 나타난다.
    func abort()
}

/// 보존해야 하는 불변식
///   - writeHead 는 응답당 정확히 한 번. 재진입은 no-op
///   - 첫 바이트가 나간 뒤에는 재분류하지 않는다. 릴레이 중 event: error 가 와도
///     원문 전달. 바이트가 소켓을 건넌 뒤에는 조직을 바꿀 수 없다
///   - 중간 실패는 end() 가 아니라 abort()
///   - 클라이언트 중단 시 업스트림까지 즉시 취소
/// docs/porting/03-sse-streaming.md 7절, 8절
/// 남은 스트림은 attempt 의 streaming 케이스가 들고 온다. 밖에서 따로 받으면
/// 스트림 없이 부르는 조합이 타입상 가능해진다.
public func relayStreaming(
    _ attempt: UpstreamAttempt,
    to client: any ClientResponseWriting,
    sniffer: inout UsageSniffer
) async throws -> ParsedUsage? {
    _ = (attempt, client, sniffer)
    throw NotImplemented(what: "relayStreaming")
}
