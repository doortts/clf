import Foundation
import NIOCore
import NIOPosix

/// 응답 바이트를 우리가 그대로 정하는 가짜 업스트림.
///
/// NIOHTTP1 서버를 쓰지 않는다. 프레이밍을 라이브러리가 대신 정해주면 정작
/// 확인하려는 것(청크가 어디서 갈리는지, content-encoding 이 어떻게 오는지)을
/// 통제할 수 없다. 여기서는 소켓에 나갈 바이트를 한 줄씩 적는다.
final class RawUpstream: @unchecked Sendable {
    /// 순서대로 쓸 응답 바이트. 여러 개면 그 경계가 그대로 TCP 청크 경계가 된다.
    let chunks: [[UInt8]]
    /// 청크 사이 간격. SSE 스트리밍을 흉내낸다.
    let gap: TimeAmount

    private let group: EventLoopGroup
    private var channel: Channel!
    private let lock = NSLock()
    private var _requests: [String] = []

    private(set) var port: Int = 0

    init(chunks: [[UInt8]], gap: TimeAmount = .milliseconds(1)) {
        self.chunks = chunks
        self.gap = gap
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    convenience init(raw: String, gap: TimeAmount = .milliseconds(1)) {
        self.init(chunks: [Array(raw.utf8)], gap: gap)
    }

    /// 헤더 문자열과 본문 바이트로 응답 하나를 만든다. content-length 는 직접 적는다.
    static func response(status: String, headers: [String], body: [UInt8]) -> [UInt8] {
        var head = "HTTP/1.1 \(status)\r\n"
        for h in headers { head += h + "\r\n" }
        head += "content-length: \(body.count)\r\n\r\n"
        return Array(head.utf8) + body
    }

    func start() throws {
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] ch in
                ch.pipeline.addHandler(Responder(owner: self))
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        port = channel.localAddress?.port ?? 0
    }

    func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }

    /// 서버가 실제로 받은 요청 원문. 우리가 무엇을 보냈는지 확인하는 유일한 근거다.
    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    fileprivate func record(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        _requests.append(text)
    }

    /// 한 이벤트 루프에만 묶여 도는 핸들러다. 루프 밖에서 건드리지 않는다.
    private final class Responder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        let owner: RawUpstream
        var accumulated: [UInt8] = []
        var responded = false

        init(owner: RawUpstream) { self.owner = owner }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            accumulated.append(contentsOf: unwrapInboundIn(data).readableBytesView)
            guard !responded else { return }

            // 바이트로 센다. 문자 수로 세면 본문이 별도 세그먼트로 왔을 때
            // 부분 디코딩이 대체 문자를 만들어 경계가 어긋나고, 본문이 도착하기
            // 전에 응답해버린다.
            guard let headEnd = Self.indexOfTerminator(accumulated) else { return }
            let bodyStart = headEnd + Self.terminator.count
            let declared = Self.contentLength(Array(accumulated[0..<headEnd])) ?? 0
            guard accumulated.count >= bodyStart + declared else { return }

            responded = true
            owner.record(String(decoding: accumulated, as: UTF8.self))
            write(chunks: owner.chunks[...], context: context)
        }

        static let terminator: [UInt8] = Array("\r\n\r\n".utf8)

        static func indexOfTerminator(_ bytes: [UInt8]) -> Int? {
            guard bytes.count >= terminator.count else { return nil }
            for i in 0...(bytes.count - terminator.count)
            where Array(bytes[i..<(i + terminator.count)]) == terminator {
                return i
            }
            return nil
        }

        /// 청크를 하나씩, 간격을 두고 쓴다. 한꺼번에 쓰면 커널이 합쳐버려
        /// 청크 경계를 시험하는 의미가 사라진다.
        private func write(chunks: ArraySlice<[UInt8]>, context: ChannelHandlerContext) {
            guard let first = chunks.first else {
                context.close(promise: nil)
                return
            }
            var buffer = context.channel.allocator.buffer(capacity: first.count)
            buffer.writeBytes(first)
            let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
            context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in
                let (handler, ctx) = bound.value
                let rest = chunks.dropFirst()
                guard !rest.isEmpty else { return ctx.close(promise: nil) }
                ctx.eventLoop.scheduleTask(in: handler.owner.gap) {
                    let (handler, ctx) = bound.value
                    handler.write(chunks: rest, context: ctx)
                }
            }
        }

        /// 헤더 구간만 넘겨받는다. 본문에 content-length 처럼 보이는 줄이 있어도
        /// 걸리지 않는다.
        private static func contentLength(_ headerBytes: [UInt8]) -> Int? {
            for line in String(decoding: headerBytes, as: UTF8.self).split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                        == "content-length" else { continue }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
    }
}

/// 위 payload 를 mtime 0 으로 고정해 만든 gzip 바이트.
///
/// 압축 자동 해제를 켜지 않으면 SSE peek 이 이 바이트를 읽는다. 프레임 경계도
/// error.type 도 찾지 못하고 스왑 판정 자체가 죽는다.
/// docs/porting/01-headers-and-auth.md 5절
enum GzipFixture {
    static let plain = #"event: error"# + "\n"
        + #"data: {"type":"error","error":{"type":"rate_limit_error"}}"# + "\n\n"

    static let compressed: [UInt8] = [
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0x4b, 0x2d,
        0x4b, 0xcd, 0x2b, 0xb1, 0x52, 0x48, 0x2d, 0x2a, 0xca, 0x2f, 0xe2, 0x4a,
        0x49, 0x2c, 0x49, 0xb4, 0x52, 0xa8, 0x56, 0x2a, 0xa9, 0x2c, 0x48, 0x55,
        0xb2, 0x52, 0x02, 0x0b, 0x2a, 0xe9, 0x40, 0x69, 0x2b, 0xb8, 0x78, 0x51,
        0x62, 0x49, 0x6a, 0x7c, 0x4e, 0x66, 0x6e, 0x66, 0x49, 0x3c, 0x44, 0xaa,
        0xb6, 0x96, 0x8b, 0x0b, 0x00, 0x31, 0x47, 0x7f, 0x7d, 0x49, 0x00, 0x00,
        0x00,
    ]
}
