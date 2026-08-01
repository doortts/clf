import Foundation

/// docs/design/02-domain-model.md 3절
public struct Selection: Sendable, Equatable {
    public let accountID: AccountID
    public let plan: Plan
    public let baseURL: URL
    public let isCrossPlan: Bool        // 직전 활성 조직과 plan 이 다른가

    public init(accountID: AccountID, plan: Plan, baseURL: URL, isCrossPlan: Bool) {
        self.accountID = accountID
        self.plan = plan
        self.baseURL = baseURL
        self.isCrossPlan = isCrossPlan
    }
}

public enum SelectionResult: Sendable, Equatable {
    case selected(Selection)
    /// 회복 가능한 조직이 있으나 아직 쿨다운 중. grace 예산 안에서 대기 후 재훑기.
    case wait(until: Date)
    /// 시간으로 회복되지 않는다. 자동 전환에서 빼둔 조직 중 지금 쓸 수 있는 것이
    /// 있으면 함께 실어 보낸다. UI 가 "무엇을 켜면 풀리는지" 를 말할 근거.
    case exhausted(unblockable: [AccountID])
}

public struct SelectionInput: Sendable {
    public let priority: [AccountID]
    public let accounts: [AccountID: Account]
    public let runtime: [AccountID: AccountRuntime]
    public let model: ModelID
    public let now: Date
    public let tried: Set<AccountID>            // 이 요청에서 이미 시도한 조직
    public let activeID: AccountID?
    public let isConversationStart: Bool        // 선제 강등을 적용할지
    public let proactiveThreshold: Double       // 잔여 기준. 기본 0.15
    public let proactiveHysteresis: Double      // tier 0 진입선을 올린다. 기본 0.10

    public init(
        priority: [AccountID], accounts: [AccountID: Account],
        runtime: [AccountID: AccountRuntime], model: ModelID, now: Date,
        tried: Set<AccountID>, activeID: AccountID?,
        isConversationStart: Bool,
        proactiveThreshold: Double = 0.15,
        proactiveHysteresis: Double = 0.10
    ) {
        self.priority = priority
        self.accounts = accounts
        self.runtime = runtime
        self.model = model
        self.now = now
        self.tried = tried
        self.activeID = activeID
        self.isConversationStart = isConversationStart
        self.proactiveThreshold = proactiveThreshold
        self.proactiveHysteresis = proactiveHysteresis
    }
}

/// 순서
///   1. priority 에서 tried 를 뺀다
///   2. autoSwitch == false 제외. 건강 상태와 무관한 사용자 의사이므로 맨 앞에서
///   3. invalid 제외
///   4. cooling(account) 제외
///   5. cooling(model) 제외 (요청 모델과 일치할 때만)
///   6. 선제 강등. **제외가 아니라 2단계 정렬**
///        tier 0 : bindingHeadroom >= threshold + hysteresis
///        tier 1 : 그 외. 읽기 없는 조직도 여기
///   7. 남은 것 중 최상위
///   8. 없으면 wait 또는 exhausted(unblockable:)
///
/// 8번의 구분이 중요하다. 일시 과부하와 진짜 소진이 같은 경로로 흐르면 시작 시
/// 풀 전체가 60초 암전된다.
///
/// 읽기 없는 후보를 제외하지 않고 tier 1 로 내리는 것은 CCSwitcher 와 다른 선택이다.
/// 그쪽은 선제 전환만 하므로 후보를 빼도 제자리에 있으면 그만이지만, 우리는 반응형
/// 경로가 있어 후보를 풀에서 빼면 429 때 넘어갈 곳이 사라진다.
public func select(_ input: SelectionInput) -> SelectionResult {
    _ = input
    fatalError("TODO")
}
