import Foundation
import ClflCore

/// best-effort append sink. **throws 하지 않는다.**
///
/// 로그 실패가 요청 경로를 막지 않는 것을 규율이 아니라 타입으로 강제한다.
/// 호출부에서 `try?` 를 쓰는 습관에 기대면 언젠가 새어나온다.
/// docs/design/04-implementation.md 6절
public protocol EventSinking: Sendable {
    func append(_ event: RoutingEvent)
    func append(_ usage: UsageRecord)
}

/// 직렬 큐에 얹는다. actor 로 만들면 append 마다 Task 를 띄워야 하는데 Task 는
/// FIFO 를 보장하지 않아 로그 순서가 뒤집힌다. 여기서는 순서가 곧 정보다.
public final class JSONLSink: EventSinking, @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.clfl.jsonl", qos: .utility)
    private let usageURL: URL
    private let auditURL: URL
    private let encoder: JSONEncoder

    public init(directory: URL) {
        self.usageURL = directory.appendingPathComponent("usage.jsonl")
        self.auditURL = directory.appendingPathComponent("audit.jsonl")

        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = e
    }

    public func append(_ event: RoutingEvent) { enqueue(event, to: auditURL) }
    public func append(_ usage: UsageRecord)  { enqueue(usage, to: usageURL) }

    /// 큐가 비워질 때까지 기다린다. 테스트와 종료 시퀀스용.
    public func drain() { queue.sync {} }

    private func enqueue<T: Encodable & Sendable>(_ value: T, to url: URL) {
        guard var encoded = try? encoder.encode(value) else { return }
        encoded.append(0x0A)
        // 큐로 넘기기 전에 불변으로 굳힌다. var 를 캡처하면 경합 경고가 난다
        let line = encoded
        queue.async { Self.appendLine(line, to: url) }
    }

    private static func appendLine(_ line: Data, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil else { return }
            try? handle.write(contentsOf: line)
            return
        }
        // 파일이 아직 없다. 디렉토리째 없을 수도 있다.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        _ = FileManager.default.createFile(
            atPath: url.path, contents: line, attributes: [.posixPermissions: 0o600])
    }
}

/// 로그를 쓰지 않는다. 테스트와 미리보기용.
public struct NullEventSink: EventSinking {
    public init() {}
    public func append(_ event: RoutingEvent) {}
    public func append(_ usage: UsageRecord) {}
}
