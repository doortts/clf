import Foundation

/// 한도 창 하나. 서버가 주는 것은 사용률이므로 잔여는 파생시킨다.
public struct Window: Codable, Sendable, Hashable {
    public var usedRatio: Double        // 0.0 ~ 1.0
    public var resetsAt: Date?
    public var remaining: Double { 1 - usedRatio }

    public init(usedRatio: Double, resetsAt: Date? = nil) {
        self.usedRatio = usedRatio
        self.resetsAt = resetsAt
    }
}

/// docs/design/02-domain-model.md 2절, 07-oauth-credentials.md 6절
public struct RateLimitSnapshot: Codable, Sendable, Hashable {
    public var fiveHour: Window?
    public var sevenDayAll: Window?

    /// 모델별 주간 창. Usage API 의 `limits[]` 에서만 온다. 응답 헤더에는 없다.
    /// Claude Code 가 보여주는 "Weekly, Fable" 행이 이것이다.
    public var modelWeekly: [ModelID: Window]

    public var observedAt: Date
    public var source: Source

    public enum Source: String, Codable, Sendable {
        case headers        // 응답 헤더 편승. 5시간과 전체 주간만
        case usageAPI       // 모델별 주간까지. user:profile 스코프 필요
    }

    public init(
        fiveHour: Window? = nil,
        sevenDayAll: Window? = nil,
        modelWeekly: [ModelID: Window] = [:],
        observedAt: Date,
        source: Source
    ) {
        self.fiveHour = fiveHour
        self.sevenDayAll = sevenDayAll
        self.modelWeekly = modelWeekly
        self.observedAt = observedAt
        self.source = source
    }
}

/// 저장되는 런타임 상태. 앱 재시작을 넘겨야 하므로 runtime.json 에 영속화한다.
public struct AccountRuntime: Codable, Sendable, Hashable {
    public var lastUsedAt: Date?

    /// 401 을 맞고 갱신도 거부된 시각. 시간으로 회복되지 않는다.
    public var invalidatedAt: Date?

    /// session_limit_error 로 인한 계정 전체 쿨다운.
    public var accountCooldownUntil: Date?

    /// rate_limit_error 로 인한 (계정, 모델) 쿨다운.
    public var modelCooldowns: [ModelID: Date]

    public var rateLimit: RateLimitSnapshot?

    public init(
        lastUsedAt: Date? = nil,
        invalidatedAt: Date? = nil,
        accountCooldownUntil: Date? = nil,
        modelCooldowns: [ModelID: Date] = [:],
        rateLimit: RateLimitSnapshot? = nil
    ) {
        self.lastUsedAt = lastUsedAt
        self.invalidatedAt = invalidatedAt
        self.accountCooldownUntil = accountCooldownUntil
        self.modelCooldowns = modelCooldowns
        self.rateLimit = rateLimit
    }
}
