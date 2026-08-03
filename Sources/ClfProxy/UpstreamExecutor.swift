import Foundation
import NIOCore
import NIOHTTP1
import AsyncHTTPClient
import ClfCore

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

/// peek 이 끝난 뒤 남은 업스트림 바이트.
///
/// 소비자가 하나라는 전제로 만든 상자다. 릴레이 한 곳만 이걸 돌린다.
/// AsyncThrowingStream 으로 옮겨 담지 않는 이유는 그러면 버퍼가 생기고
/// `await` 이 곧 backpressure 라는 성질을 잃기 때문이다.
public final class UpstreamByteStream: @unchecked Sendable {
    private let advance: () async throws -> ByteBuffer?

    public init(advance: @escaping () async throws -> ByteBuffer?) {
        self.advance = advance
    }

    public func next() async throws -> ByteBuffer? { try await advance() }

    public static var empty: UpstreamByteStream { UpstreamByteStream { nil } }

    /// AsyncIterator 를 그대로 감싼다. peek 이 쓰던 그 iterator 를 이어서 돌린다.
    public static func wrapping<I: AsyncIteratorProtocol>(
        _ iterator: I
    ) -> UpstreamByteStream where I.Element == ByteBuffer {
        let box = Box(iterator)
        return UpstreamByteStream { try await box.next() }
    }

    private final class Box<I: AsyncIteratorProtocol>: @unchecked Sendable
    where I.Element == ByteBuffer {
        var iterator: I
        init(_ iterator: I) { self.iterator = iterator }
        func next() async throws -> ByteBuffer? { try await iterator.next() }
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
    /// firstFrameBytes 로 분류하고 tail 과 rest 를 이어서 릴레이한다.
    ///
    /// rest 가 케이스 안에 있어야 한다. 밖에 두면 릴레이가 스트림 없이 attempt 만
    /// 받는 조합이 타입상 가능해지고, 그 경우 첫 프레임만 내보내고 조용히 끝난다.
    case streaming(status: Int, headers: HeaderBag,
                   firstFrameBytes: [UInt8], tail: [UInt8], rest: UpstreamByteStream)
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
    /// 응답 머리를 받기까지의 한도. 본문 스트리밍에는 걸지 않는다.
    /// 긴 생성이 도중에 끊기면 스왑도 재생도 못 한다.
    public static let headTimeout: TimeAmount = .seconds(120)

    /// 버퍼 응답 상한. 여기 걸리는 것은 Anthropic 응답이 아니다.
    public static let maxBufferedBytes = 64 * 1024 * 1024

    /// 붙는 데까지의 한도. AsyncHTTPClient 기본값은 10초인데 그러면 닿지 않는
    /// 조직 하나가 요청을 10초씩 붙잡는다. 조직 셋이면 30초라 풀 grace 예산
    /// 15초를 훌쩍 넘겨 스왑이 의미를 잃는다.
    public static let defaultConnectTimeout: TimeAmount = .seconds(5)

    private let client: HTTPClient

    public init(connectTimeout: TimeAmount = HTTPUpstreamExecutor.defaultConnectTimeout) {
        var configuration = HTTPClient.Configuration()
        // 이 한 줄이 이 타입의 존재 이유다. ratio 25 는 zip bomb 가드다
        configuration.decompression = .enabled(limit: .ratio(25))
        configuration.timeout.connect = connectTimeout
        self.client = HTTPClient(eventLoopGroupProvider: .singleton,
                                 configuration: configuration)
    }

    public func shutdown() async {
        try? await client.shutdown()
    }

    public func execute(_ req: UpstreamRequest) async throws -> UpstreamAttempt {
        var request = HTTPClientRequest(url: req.url)
        request.method = HTTPMethod(rawValue: req.method)
        for (key, value) in req.headers.storage {
            request.headers.add(name: key, value: value)
        }
        // 빈 본문에 content-length: 0 을 붙이면 게이트웨이가 GET 을 거부하기도 한다
        if !req.body.isEmpty {
            request.body = .bytes(ByteBuffer(bytes: req.body))
        }

        let response = try await client.execute(request, timeout: Self.headTimeout)
        let status = Int(response.status.code)
        var headers = HeaderBag()
        for header in response.headers {
            headers[header.name] = header.value
        }

        guard isEventStream(headers) else {
            let body = try await response.body.collect(upTo: Self.maxBufferedBytes)
            return .buffered(status: status, headers: headers,
                             body: Array(body.readableBytesView), isSSE: false)
        }

        // 클라이언트에 한 바이트도 쓰기 전에 첫 프레임을 본다. 이것이 스왑의 전제다
        var iterator = response.body.makeAsyncIterator()
        let peeked = try await peekFirstSSEFrame(&iterator)
        return .streaming(status: status, headers: headers,
                          firstFrameBytes: peeked.firstFrameBytes,
                          tail: peeked.tail,
                          rest: peeked.closedEmpty
                              ? .empty
                              : .wrapping(iterator))
    }

    /// content-type 하나로 정한다. status 로 추측하지 않는다.
    /// 200 으로 시작한 스트림의 첫 프레임이 error 인 경우가 실제로 있다.
    private func isEventStream(_ headers: HeaderBag) -> Bool {
        guard let contentType = headers["content-type"] else { return false }
        return contentType.lowercased().contains("text/event-stream")
    }
}
