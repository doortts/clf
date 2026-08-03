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
        lineBuf.append(contentsOf: chunk)
        var out: [SSEEvent] = []
        while let nl = lineBuf.firstIndex(of: LF) {
            var lineBytes = Array(lineBuf[..<nl])
            if lineBytes.last == CR { lineBytes.removeLast() }   // CRLF 정규화
            lineBuf.removeFirst(nl + 1)
            if let event = handleLine(String(decoding: lineBytes, as: UTF8.self)) {
                out.append(event)
            }
        }
        return out
    }

    /// 종단 빈 줄 없이 업스트림이 깨끗하게 닫혔을 때 남은 이벤트를 흘려보낸다.
    public mutating func flush() -> [SSEEvent] {
        var out: [SSEEvent] = []
        if !lineBuf.isEmpty {
            let line = String(decoding: lineBuf, as: UTF8.self)
            lineBuf.removeAll()
            if let event = handleLine(line) { out.append(event) }
        }
        if let trailing = emit() { out.append(trailing) }
        return out
    }

    private mutating func handleLine(_ line: String) -> SSEEvent? {
        if line.isEmpty { return emit() }           // 빈 줄 = 프레임 종단
        if line.hasPrefix(":") { return nil }       // 주석

        let colon = line.firstIndex(of: ":")
        let field = colon.map { String(line[..<$0]) } ?? line
        var value = colon.map { String(line[line.index(after: $0)...]) } ?? ""
        if value.hasPrefix(" ") { value.removeFirst() }   // 선행 공백 1개만 제거

        inFrame = true
        switch field {
        case "event": currentEvent = value
        case "data":  currentData.append(value)
        default:      break                         // id / retry / unknown: 수용하되 무시
        }
        return nil
    }

    private mutating func emit() -> SSEEvent? {
        guard inFrame else { return nil }
        let event = SSEEvent(event: currentEvent, data: currentData.joined(separator: "\n"))
        currentEvent = ""
        currentData.removeAll()
        inFrame = false
        return event
    }
}

/// 버퍼 하나에서 첫 완성 이벤트만 뽑는 편의 함수. peek 결과 판정에 쓴다.
public func parseFirstSSEEvent(_ bytes: [UInt8]) -> SSEEvent? {
    var parser = SSEParser()
    return parser.push(bytes).first
}
