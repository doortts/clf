import Foundation
import ClflCore

/// 요청 하나의 판단 과정.
///
/// `audit.jsonl` 은 **사건**을 남기고 이것은 **과정**을 남긴다. 스왑이 일어난
/// 것은 audit 에 있지만 왜 team2 를 건너뛰고 ent1 로 갔는지는 없다.
///
/// 같은 레코드를 세 곳이 쓴다. `clflctl serve` 가 찍는 한 줄, 컨트롤 플레인의
/// `GET /requests`, 나중에 스왑 루프가 붙일 후보 목록이다. 갈라 두면 설명이
/// 언제든 거짓말을 시작한다. docs/design/08-verification.md 3절, 5절
public struct RequestTrace: Sendable {
    public let at: Date
    public let method: String
    public let uri: String
    public let model: ModelID?
    public let sessionID: SessionID?
    public let account: AccountID?
    public let status: Int?
    public let isStreaming: Bool
    public let bytes: Int
    /// 첫 바이트가 클라이언트로 나가기까지. 체감 지연은 이 값이다.
    public let firstByteMillis: Int?
    public let totalMillis: Int?
    public let outcome: Outcome

    public enum Outcome: Sendable, Equatable {
        case ok
        /// 클라이언트에 한 바이트도 쓰기 전에 끝났다. 스왑이 가능한 지점이다.
        case failed(reason: String)
        /// 첫 바이트가 나간 뒤 끊겼다. 사용자는 반쯤 받았고 되돌릴 수 없다.
        case aborted
    }

    public init(
        at: Date, method: String, uri: String,
        model: ModelID?, sessionID: SessionID?, account: AccountID?,
        status: Int?, isStreaming: Bool, bytes: Int,
        firstByteMillis: Int?, totalMillis: Int?, outcome: Outcome
    ) {
        self.at = at
        self.method = method
        self.uri = uri
        self.model = model
        self.sessionID = sessionID
        self.account = account
        self.status = status
        self.isStreaming = isStreaming
        self.bytes = bytes
        self.firstByteMillis = firstByteMillis
        self.totalMillis = totalMillis
        self.outcome = outcome
    }

    /// 실기기 확인에서 이 한 줄이 관측의 전부다.
    ///
    /// 모델 이름은 뒤가 다르고 앞이 같으므로 접두사를 떼고 보여준다.
    /// 화면 폭이 좁은데 `claude-` 일곱 글자가 매번 같은 자리를 먹는다.
    public var line: String {
        var parts = [Self.clock.string(from: at),
                     method,
                     uri.count > 40 ? String(uri.prefix(39)) + "~" : uri]

        parts.append(account ?? "-")
        if let model { parts.append(model.replacingOccurrences(of: "claude-", with: "")) }
        if isStreaming { parts.append("SSE") }
        parts.append(sessionID.map { "s:" + String($0.prefix(8)) } ?? "세션없음")

        switch outcome {
        case .ok:
            parts.append("\(status ?? 0)")
            parts.append("\(bytes)B")
            if let firstByteMillis { parts.append("첫바이트 \(firstByteMillis)ms") }
            if let totalMillis { parts.append("총 \(totalMillis)ms") }
        case .aborted:
            parts.append("중단 (\(bytes)B 나간 뒤)")
        case .failed(let reason):
            parts.append("실패: \(reason)")
        }
        return parts.joined(separator: "  ")
    }

    /// 컨트롤 플레인이 그대로 내보낸다.
    ///
    /// 모르는 것은 키를 빼지 0 으로 적지 않는다. 관측하지 못한 것과 0으로
    /// 관측한 것은 다르다.
    public var jsonObject: [String: Any] {
        var out: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: at),
            "method": method,
            "uri": uri,
            "streaming": isStreaming,
            "bytes": bytes,
        ]
        if let model { out["model"] = model }
        if let sessionID { out["session_id"] = sessionID }
        if let account { out["account"] = account }
        if let status { out["status"] = status }
        if let firstByteMillis { out["first_byte_ms"] = firstByteMillis }
        if let totalMillis { out["total_ms"] = totalMillis }

        switch outcome {
        case .ok:                  out["outcome"] = "ok"
        case .aborted:             out["outcome"] = "aborted"
        case .failed(let reason):  out["outcome"] = "failed"
                                   out["reason"] = reason
        }
        return out
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// 최근 것만 남기는 고리 버퍼.
///
/// 진단용이라 무한히 쌓을 이유가 없고, 디스크에 남기면 무엇을 언제 지울지
/// 다시 정해야 한다. 재시작을 넘길 이유도 없다.
public final class TraceRing: @unchecked Sendable {
    public static let defaultCapacity = 200

    private let capacity: Int
    private let lock = NSLock()
    private var items: [RequestTrace] = []

    public init(capacity: Int = TraceRing.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public func append(_ trace: RequestTrace) {
        lock.lock(); defer { lock.unlock() }
        items.append(trace)
        if items.count > capacity { items.removeFirst(items.count - capacity) }
    }

    /// 오래된 것부터 최신 순. limit 을 주면 최신 쪽에서 잘라낸다.
    public func recent(limit: Int? = nil) -> [RequestTrace] {
        lock.lock(); defer { lock.unlock() }
        guard let limit, limit < items.count else { return items }
        return Array(items.suffix(limit))
    }
}
