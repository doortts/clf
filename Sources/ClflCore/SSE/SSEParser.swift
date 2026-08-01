/// docs/porting/03-sse-streaming.md 5절
public struct SSEEvent: Equatable, Sendable {
    public let event: String    // `event:` 필드. 없으면 빈 문자열
    public let data: String     // 여러 `data:` 줄을 \n 으로 join

    public init(event: String, data: String) {
        self.event = event
        self.data = data
    }
}

/// 증분 SSE 파서.
///
/// 줄을 **바이트 단위로** 자른다. 청크마다 문자열로 변환하면 멀티바이트 UTF-8 이
/// 청크 경계에 걸릴 때 손상된다. LF(0x0A) 는 멀티바이트 시퀀스 안에 나타날 수
/// 없으므로 줄 프레이밍은 안전하고, 줄이 완성된 시점은 항상 유효한 UTF-8 경계다.
public struct SSEParser: Sendable {
    private var lineBuf: [UInt8] = []
    private var currentEvent = ""
    private var currentData: [String] = []
    private var inFrame = false

    public init() {}

    /// 청크를 밀어 넣고 완성된 이벤트를 모두 받는다. 부분 줄/프레임은 버퍼링된다.
    public mutating func push(_ chunk: [UInt8]) -> [SSEEvent] {
        _ = chunk
        fatalError("TODO")
    }

    /// 종단 빈 줄 없이 업스트림이 깨끗하게 닫혔을 때 남은 이벤트를 흘려보낸다.
    public mutating func flush() -> [SSEEvent] {
        fatalError("TODO")
    }
}

/// 버퍼 하나에서 첫 완성 이벤트만 뽑는 편의 함수. peek 결과 판정에 쓴다.
public func parseFirstSSEEvent(_ bytes: [UInt8]) -> SSEEvent? {
    _ = bytes
    fatalError("TODO")
}
