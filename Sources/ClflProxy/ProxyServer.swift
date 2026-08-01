import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// 로컬 HTTP 서버. NIOAsyncChannel 로 받아 요청당 Task 로 넘긴다.
///
/// 웹 프레임워크를 쓰지 않는 이유: 라우팅, 미들웨어, 템플릿, 콘텐츠 협상이 전혀
/// 필요없고 SSE 릴레이가 요구하는 바이트 제어를 프레임워크가 감춘다.
/// docs/design/04-implementation.md 1절
public struct ProxyServer: Sendable {
    public init(pipeline: RequestPipeline) { _ = pipeline; fatalError("TODO") }

    /// 실제로 바인딩된 포트를 낸다. 요청 포트가 점유돼 있으면 다음 빈 포트로
    /// 폴백하므로 호출자는 반환값으로 settings.json 을 갱신해야 한다.
    /// 바인딩 자체가 단일 인스턴스 락 역할을 한다.
    public func start(port: UInt16) async throws -> UInt16 {
        _ = port
        fatalError("TODO")
    }

    public func shutdown() async { fatalError("TODO") }
}
