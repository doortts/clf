import Foundation

/// docs/porting/02-response-classification.md 1절
public enum SwapTrigger: Equatable, Sendable {
    case rateLimit(accountID: AccountID, resetEpoch: Int, sessionID: SessionID)
    case sessionLimit(accountID: AccountID, resetEpoch: Int, sessionID: SessionID)
    case authentication(accountID: AccountID, sessionID: SessionID)

    /// 분류기는 절대 생성하지 않는다. 스왑 루프의 종단 분기 전용.
    /// 같은 enum 에 두는 이유는 소비자가 하나의 exhaustive switch 를 쓰게 하려고.
    case poolExhausted(accountID: AccountID?, sessionID: SessionID)
}

public struct ClassifyInput: Sendable {
    public let status: Int
    public let headers: HeaderBag
    /// 비스트리밍 본문. firstSSEEvent 와 상호배타.
    public let body: Data?
    /// 스트리밍이면 peek 한 첫 이벤트.
    public let firstSSEEvent: SSEEvent?
    public let accountID: AccountID
    public let sessionID: SessionID
    /// epoch 초. retry-after 계산의 기준점.
    public let now: Int

    public init(
        status: Int, headers: HeaderBag, body: Data? = nil,
        firstSSEEvent: SSEEvent? = nil,
        accountID: AccountID, sessionID: SessionID, now: Int
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.firstSSEEvent = firstSSEEvent
        self.accountID = accountID
        self.sessionID = sessionID
        self.now = now
    }
}
