/// 릴레이 중 흘러가는 SSE 에서 토큰 수를 줍는다.
/// 마지막 `message_delta` 이벤트가 최종 usage 를 담는다.
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
    private var latest: ParsedUsage?

    public init() {}

    public mutating func push(_ chunk: [UInt8]) {
        _ = chunk
        fatalError("TODO: 파서에 흘리고 message_start / message_delta 에서 usage 누적")
    }

    public mutating func finish() -> ParsedUsage? {
        fatalError("TODO")
    }
}
