import Foundation
import NIOCore
import ClflCore

public struct UpstreamRequest: Sendable {
    public let url: String
    public let method: String
    public let headers: HeaderBag
    public let body: [UInt8]

    public init(url: String, method: String, headers: HeaderBag, body: [UInt8]) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// 업스트림 시도 결과. 형태는 content-type 으로 한 번만 정해진다.
///
/// union 인 이유: 스왑 루프가 **컴파일 타임에** 재생 가능한 버퍼를 쥐고 있는지
/// 라이브 스트림을 쥐고 있는지 알아야 한다. 옵셔널 섞인 하나의 형태로 만들면
/// 호출 지점마다 길이 검사가 생기고 두 모드 간 조용한 fall-through 를 막는
/// exhaustiveness 를 잃는다.
public enum UpstreamAttempt: Sendable {
    /// 응답 전체 바이트. 풀 소진 시 원문 재생과 분류 양쪽에서 읽는다.
    case buffered(status: Int, headers: HeaderBag, body: [UInt8], isSSE: Bool)
    /// firstFrameBytes 로 분류하고 나머지는 청크 단위로 릴레이한다.
    case streaming(status: Int, headers: HeaderBag, firstFrameBytes: [UInt8], tail: [UInt8])
}

public protocol UpstreamExecuting: Sendable {
    func execute(_ req: UpstreamRequest) async throws -> UpstreamAttempt
}

/// AsyncHTTPClient 구현.
///
/// **압축 자동 해제를 반드시 켠다.** 끄면 SSE peek 이 gzip 바이트를 읽어 프레임
/// 경계도 error.type 도 찾지 못하고 스왑 판정 자체가 죽는다. AsyncHTTPClient 는
/// 기본이 .disabled 다. docs/porting/01-headers-and-auth.md 5절
public struct HTTPUpstreamExecutor: UpstreamExecuting {
    public init() { fatalError("TODO: HTTPClient.Configuration(decompression: .enabled(limit: .ratio(25)))") }

    public func execute(_ req: UpstreamRequest) async throws -> UpstreamAttempt {
        _ = req
        fatalError("TODO")
    }
}
