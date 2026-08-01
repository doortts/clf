import Foundation

/// 계정의 "상태" 는 저장 대상이 아니라 계산 결과다. 저장하면 시각이 흐르며 stale 해진다.
/// docs/design/02-domain-model.md 2절
public enum Availability: Sendable, Equatable {
    case active                                     // 지금 이 요청이 쓰는 조직
    case ready
    case cooling(until: Date, scope: CooldownScope)
    case invalid(since: Date)
}

public enum CooldownScope: Sendable, Equatable {
    case account            // session_limit. 모든 모델이 막힘
    case model(ModelID)     // rate_limit. 그 모델만 막힘
}

/// 모델 범위 쿨다운이 이 모델의 핵심이다. 같은 조직이 한 모델에는 cooling 이고
/// 다른 모델에는 ready 일 수 있다. 그래서 model 을 인자로 받는다.
public func availability(
    _ r: AccountRuntime,
    for model: ModelID,
    now: Date,
    activeID: AccountID?,
    id: AccountID
) -> Availability {
    _ = (r, model, now, activeID, id)
    fatalError("TODO: invalid -> account cooling -> model cooling -> active/ready 순")
}

/// 스왑 결과를 런타임 상태에 적용한다. docs/design/02-domain-model.md 4절
public enum RoutingOutcome: Sendable {
    case success(usage: ParsedUsage?, rateLimit: RateLimitSnapshot?)
    case rateLimited(model: ModelID, until: Date, transient: Bool)
    case sessionLimited(until: Date)
    case invalidated
    case passthrough                 // 스왑 대상이 아닌 응답
}

/// 동시 요청이 같은 조직에 쿨다운을 적용하면 나중 값으로 덮어쓴다.
/// 최신 429 가 가장 신선한 reset_epoch 를 들고 있기 때문이다.
public func apply(_ outcome: RoutingOutcome, to runtime: inout AccountRuntime, now: Date) {
    _ = (outcome, runtime, now)
    fatalError("TODO")
}
