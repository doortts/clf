import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import ClflCore

/// 로컬 HTTP 서버. NIOAsyncChannel 로 받아 요청당 Task 로 넘긴다.
///
/// 웹 프레임워크를 쓰지 않는 이유: 라우팅, 미들웨어, 템플릿, 콘텐츠 협상이 전혀
/// 필요없고 SSE 릴레이가 요구하는 바이트 제어를 프레임워크가 감춘다.
/// docs/design/04-implementation.md 1절

/// 요청 하나를 처리하는 쪽. 단일 조직 통과(8단계)와 스왑 루프(9단계)가
/// 같은 구멍에 꽂힌다. 서버가 파이프라인을 직접 알 이유가 없다.
public protocol RequestHandling: Sendable {
    func handle(method: String, uri: String, headers: HeaderBag, body: [UInt8],
                client: any ClientResponseWriting) async
}

public final class ProxyServer: @unchecked Sendable {
    /// 요청 본문 상한. 이 위로는 재전송 사본을 들 수 없어 스왑도 못 한다.
    public static let maxRequestBytes = 32 * 1024 * 1024

    private let handler: any RequestHandling
    private let group: EventLoopGroup
    private let lock = NSLock()
    private var channel: Channel?

    public init(handler: any RequestHandling) {
        self.handler = handler
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    /// 실제로 바인딩된 포트를 낸다. 요청 포트가 점유돼 있으면 다음 빈 포트로
    /// 폴백하므로 호출자는 반환값으로 settings.json 을 갱신해야 한다.
    /// 바인딩 자체가 단일 인스턴스 락 역할을 한다.
    public func start(port: UInt16) async throws -> UInt16 {
        let handler = self.handler
        let bound = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 64)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            // 스트리밍 응답이 니글 알고리즘에 묶이면 프레임이 뭉쳐 나간다
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true)
                    .flatMapThrowing {
                        try channel.pipeline.syncOperations.addHandler(
                            RequestCollector(handler: handler))
                    }
            }
            .bind(host: "127.0.0.1", port: Int(port))
            .get()

        store(bound)
        return UInt16(bound.localAddress?.port ?? 0)
    }

    public func shutdown() async {
        let bound = take()
        try? await bound?.close().get()
        try? await group.shutdownGracefully()
    }

    // async 함수 안에서는 NSLock 을 직접 잡을 수 없다. 동기 함수로 감싼다.
    private func store(_ bound: Channel) { lock.lock(); channel = bound; lock.unlock() }
    private func take() -> Channel? {
        lock.lock(); defer { lock.unlock() }
        let bound = channel
        channel = nil
        return bound
    }
}

/// 요청 하나를 모아 핸들러에게 넘긴다.
///
/// 본문을 전부 모으고 나서 부른다. 스트리밍 업로드를 지원하지 않는 것은 의도다.
/// 스왑하려면 재전송할 사본이 있어야 하고, 사본을 들려면 어차피 다 읽어야 한다.
private final class RequestCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let handler: any RequestHandling
    var head: HTTPRequestHead?
    var body: [UInt8] = []
    var tooLarge = false

    init(handler: any RequestHandling) { self.handler = handler }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let requestHead):
            head = requestHead
            body.removeAll(keepingCapacity: true)
            tooLarge = false

        case .body(var buffer):
            guard !tooLarge else { return }
            if body.count + buffer.readableBytes > ProxyServer.maxRequestBytes {
                tooLarge = true
                body.removeAll(keepingCapacity: false)
                return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes)
            }

        case .end:
            guard let requestHead = head else { return }
            let writer = ChannelResponseWriter(channel: context.channel,
                                               keepAlive: requestHead.isKeepAlive)
            let collected = body
            let oversize = tooLarge
            head = nil
            body = []

            var bag = HeaderBag()
            for header in requestHead.headers { bag[header.name] = header.value }
            let method = requestHead.method.rawValue
            let uri = requestHead.uri
            let handler = self.handler

            Task {
                guard !oversize else {
                    // 재전송 사본을 못 드는 크기다. 조용히 자르지 않고 말한다
                    writer.writeHead(status: 413, headers: HeaderBag())
                    let message = #"{"type":"error","error":{"type":"invalid_request_error","#
                        + #""message":"clfl: request body too large to relay"}}"#
                    try? await writer.write(Array(message.utf8))
                    writer.end()
                    return
                }
                await handler.handle(method: method, uri: uri, headers: bag,
                                     body: collected, client: writer)
            }
        }
    }
}

/// NIO 채널에 붙은 클라이언트 쓰기 표면.
///
/// 채널은 스레드 안전하므로 이벤트 루프 밖의 Task 에서 그대로 쓴다.
/// `writeAndFlush` 의 future 를 기다리는 것이 곧 backpressure 다.
final class ChannelResponseWriter: ClientResponseWriting, @unchecked Sendable {
    private let channel: Channel
    private let keepAlive: Bool
    private let lock = NSLock()
    private var _headersSent = false
    private var closed = false

    init(channel: Channel, keepAlive: Bool) {
        self.channel = channel
        self.keepAlive = keepAlive
    }

    var headersSent: Bool { lock.lock(); defer { lock.unlock() }; return _headersSent }

    var isAlive: Bool { !isClosed && channel.isActive }

    /// async 함수 안에서는 NSLock 을 직접 잡을 수 없다. 동기 접근자로 감싼다.
    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func writeHead(status: Int, headers: HeaderBag) {
        lock.lock()
        guard !_headersSent else { lock.unlock(); return }   // 응답당 정확히 한 번
        _headersSent = true
        lock.unlock()

        var out = HTTPHeaders()
        for (key, value) in headers.storage { out.add(name: key, value: value) }
        // 길이를 모른 채 흘리므로 프레이밍은 chunked 다. content-length 는
        // 릴레이가 이미 떼어냈다. 둘 다 없으면 NIO 가 연결 종료로 경계를
        // 표시하는데 그러면 keep-alive 가 깨진다
        if out.first(name: "content-length") == nil {
            out.replaceOrAdd(name: "transfer-encoding", value: "chunked")
        }

        let head = HTTPResponseHead(version: .http1_1,
                                    status: .init(statusCode: status),
                                    headers: out)
        channel.writeAndFlush(HTTPServerResponsePart.head(head), promise: nil)
    }

    func write(_ bytes: [UInt8]) async throws {
        guard !isClosed, channel.isActive else { throw ProxyError.clientDisconnected }
        let part = HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: bytes)))
        do {
            try await channel.writeAndFlush(part).get()
        } catch {
            throw ProxyError.clientDisconnected
        }
    }

    func end() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()

        let channel = self.channel
        let keepAlive = self.keepAlive
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
            if !keepAlive { channel.close(promise: nil) }
        }
    }

    /// 종단자를 보내지 않고 소켓을 끊는다. end() 를 부르면 잘린 스트림이
    /// 완결된 것처럼 보이고 Claude Code 에서 응답이 멈춘 것으로 나타난다.
    func abort() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        channel.close(promise: nil)
    }
}
