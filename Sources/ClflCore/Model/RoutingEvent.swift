import Foundation

/// 지속 조건. 참인 동안 UI 에 계속 보인다. 시간 기반 dedupe 를 두지 않는다.
/// docs/design/02-domain-model.md 5절
public enum Condition: Hashable, Sendable {
    case crossPlanActive(from: AccountID, to: AccountID)
    case accountInvalid(AccountID)
    case poolExhausted
    /// 자동 전환 대상이 0개다. 모든 요청이 실패한다.
    case autoSwitchAllDisabled
    /// 토큰 만료가 7일 이내. longLived 자격증명에만 해당.
    case tokenExpiringSoon(AccountID, daysLeft: Int)
    /// settings.json 에 우리 값이 없다.
    case proxyDetached
}

/// 순간 사건. 타임라인에 append 하고 지우지 않는다.
public struct RoutingEvent: Codable, Sendable {
    public let at: Date
    public let sessionID: SessionID?
    public let kind: Kind

    public enum Kind: Codable, Sendable {
        case swap(from: AccountID, to: AccountID, trigger: String, crossPlan: Bool)
        case poolExhausted(lastTried: AccountID?)
        case largeRequestSkipped(bytes: Int)
        case accountInvalidated(AccountID)
        /// 갱신으로 401 을 흡수했다. 사용자에게는 안 보이지만 기록은 남긴다.
        case credentialRefreshed(AccountID)
    }

    public init(at: Date, sessionID: SessionID?, kind: Kind) {
        self.at = at
        self.sessionID = sessionID
        self.kind = kind
    }
}

/// usage.jsonl 한 줄. 캐시 두 필드를 반드시 남긴다.
/// docs/design/02-domain-model.md 6절
public struct UsageRecord: Codable, Sendable {
    public let ts: Date
    public let account: AccountID
    public let model: ModelID?
    public let sessionID: SessionID?
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationInputTokens: Int
    public let cacheReadInputTokens: Int

    public init(
        ts: Date, account: AccountID, model: ModelID?, sessionID: SessionID?,
        inputTokens: Int, outputTokens: Int,
        cacheCreationInputTokens: Int, cacheReadInputTokens: Int
    ) {
        self.ts = ts
        self.account = account
        self.model = model
        self.sessionID = sessionID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }
}
