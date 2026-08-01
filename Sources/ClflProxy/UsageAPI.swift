import Foundation
import ClflCore

/// 모델별 주간 한도의 유일한 출처.
/// docs/design/07-oauth-credentials.md 6절
///
/// ```
/// GET https://api.anthropic.com/api/oauth/usage
/// Authorization: Bearer <accessToken>
/// anthropic-beta: oauth-2025-04-20
/// ```
///
/// 403 은 대개 활성 구독이 없거나 스코프가 모자란 것이다.
public struct UsageAPIClient: Sendable {
    public static let url = "https://api.anthropic.com/api/oauth/usage"

    public init() {}

    /// `limits[]` 중 kind == "weekly_scoped" 이고 모델 스코프가 있는 항목이
    /// 모델별 주간 창이다.
    public func fetch(accessToken: String) async throws -> RateLimitSnapshot {
        _ = accessToken
        fatalError("TODO")
    }
}

/// 폴링하지 않는다. 수요가 있을 때만 부른다.
///
///   캡처 직후 / 갱신 직후 / 팝오버 열림 / 선제 판단 / 후보 검증(최상위 1건)
///
/// 가드
///   - 조직당 최소 간격 5분. 그 안에는 캐시된 스냅샷을 쓴다
///   - 동시 1건
///   - 실패는 라우팅을 막지 않는다
///   - 429 면 Retry-After 만큼 그 조직 조회를 쉰다. 사용량을 물어보다 사용량을
///     소진하는 것은 앞뒤가 맞지 않는다
public actor UsageRefresher {
    public static let minInterval: TimeInterval = 300

    public enum Reason: Sendable {
        case captured, tokenRefreshed, popoverOpened, proactiveDecision, candidateVerification
    }

    public init(client: UsageAPIClient, tokens: TokenProvider, clock: any Clock) {
        _ = (client, tokens, clock)
        fatalError("TODO")
    }

    /// 간격 안이거나 이미 비행 중이면 아무것도 하지 않고 nil 을 낸다.
    public func refreshIfStale(_ id: AccountID, reason: Reason) async -> RateLimitSnapshot? {
        _ = (id, reason)
        fatalError("TODO")
    }
}
