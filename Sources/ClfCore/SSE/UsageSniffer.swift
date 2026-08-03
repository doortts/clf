import Foundation

/// 릴레이 중 흘러가는 SSE 에서 토큰 수를 줍는다.
///
/// Anthropic 스트림은 두 곳에 usage 를 싣는다.
///   message_start  -> message.usage 에 입력과 캐시 토큰
///   message_delta  -> usage 에 최종 output_tokens
/// 마지막 값이 이긴다.
public struct ParsedUsage: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int

    public init(
        inputTokens: Int = 0, outputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0, cacheReadInputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }
}

public struct UsageSniffer: Sendable {
    private var parser = SSEParser()
    private var usage: ParsedUsage?

    public init() {}

    public mutating func push(_ chunk: [UInt8]) {
        for event in parser.push(chunk) { absorb(event) }
    }

    public mutating func finish() -> ParsedUsage? {
        for event in parser.flush() { absorb(event) }
        return usage
    }

    private mutating func absorb(_ event: SSEEvent) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
              let root = object as? [String: Any] else { return }
        // message_start 는 message 안에, message_delta 는 최상위에 usage 를 둔다
        let container = (root["message"] as? [String: Any]) ?? root
        guard let raw = container["usage"] as? [String: Any] else { return }

        var next = usage ?? ParsedUsage()
        if let v = raw["input_tokens"] as? Int { next.inputTokens = v }
        if let v = raw["output_tokens"] as? Int { next.outputTokens = v }
        if let v = raw["cache_creation_input_tokens"] as? Int { next.cacheCreationInputTokens = v }
        if let v = raw["cache_read_input_tokens"] as? Int { next.cacheReadInputTokens = v }
        usage = next
    }
}
