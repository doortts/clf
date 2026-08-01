/// SSE 프레임 경계 스캐너. docs/porting/03-sse-streaming.md 3절
///
/// **peek 은 파싱이 아니다.** 이 단계는 프레임 경계만 찾는다. 필드 파싱은 SSEParser.
/// 스트림을 소비하는 루프는 ClflProxy 의 SSEPeek 에 있다. 경계 판정 알고리즘만
/// 여기 두는 이유는 그래야 오프라인 테스트가 된다.

public let LF: UInt8 = 0x0A
public let CR: UInt8 = 0x0D

public struct SSEBoundary: Equatable, Sendable {
    public let index: Int       // 종단이 시작되는 위치
    public let length: Int      // 2 (\n\n) 또는 4 (\r\n\r\n)

    public init(index: Int, length: Int) {
        self.index = index
        self.length = length
    }
}

/// 가장 이른 위치의 매치를 반환한다. 같은 인덱스에서 둘 다 시작하면 LF 쪽이 이긴다
/// (정상 CRLF 스트림에서는 발생하지 않지만 tie-break 를 결정적으로 두기 위함).
public func findSSEBoundary(_ bytes: [UInt8], from: Int) -> SSEBoundary? {
    let n = bytes.count
    guard n >= 2 else { return nil }
    var i = max(0, from)
    while i < n - 1 {
        if bytes[i] == LF, bytes[i + 1] == LF {
            return SSEBoundary(index: i, length: 2)
        }
        if i + 3 < n,
           bytes[i] == CR, bytes[i + 1] == LF,
           bytes[i + 2] == CR, bytes[i + 3] == LF {
            return SSEBoundary(index: i, length: 4)
        }
        i += 1
    }
    return nil
}

/// 종단 빈 줄을 제외한 내용의 모든 비어있지 않은 줄이 `:` 로 시작하면 주석 전용.
/// 의도적으로 전체 이벤트 파싱이 아니라 줄 접두사 검사만 한다.
public func isCommentOnlyFrame(_ content: ArraySlice<UInt8>) -> Bool {
    if content.isEmpty { return true }
    let text = String(decoding: content, as: UTF8.self)
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
        if line.isEmpty { continue }
        if !line.hasPrefix(":") { return false }
    }
    return true
}
