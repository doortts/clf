import Foundation
import ClfCore

/// UI 로 넘어가는 값 타입 스냅샷. 토큰은 절대 싣지 않는다.
public struct RouterSnapshot: Sendable, Equatable {
    public var accounts: [Account]
    public var priority: [AccountID]
    public var runtime: [AccountID: AccountRuntime]
    public var activeID: AccountID?
    public var conditions: Set<Condition>

    public static let empty = RouterSnapshot(
        accounts: [], priority: [], runtime: [:], activeID: nil, conditions: []
    )

    public init(
        accounts: [Account], priority: [AccountID],
        runtime: [AccountID: AccountRuntime], activeID: AccountID?,
        conditions: Set<Condition>
    ) {
        self.accounts = accounts
        self.priority = priority
        self.runtime = runtime
        self.activeID = activeID
        self.conditions = conditions
    }
}

/// setup-token 은 1년짜리다. docs/design/07-oauth-credentials.md 8절
let longLivedTokenLifetime: TimeInterval = 365 * 86_400
let tokenExpiryWarningDays = 7

/// 런타임 상태의 유일한 가변 소유자.
///
/// **절대 규칙: 업스트림 I/O 를 await 하지 않는다.**
/// select 와 apply 는 마이크로초 단위여야 한다. 네트워크 왕복을 actor 안에서
/// 기다리면 동시 요청 전체가 직렬화된다.
/// docs/design/01-architecture.md 3절
public actor Router {
    /// 선제 전환에만 건다. **반응형에는 걸지 않는다.**
    /// 429 는 우리 판단이 아니라 서버의 사실 통보다. 쿨다운으로 막으면 요청이
    /// 그냥 실패한다. docs/design/02-domain-model.md 3-4절
    public static let proactiveCooldown: TimeInterval = 300

    private let clock: any Clock
    private let coalesce: Duration

    private var accounts: [AccountID: Account] = [:]
    private var priority: [AccountID] = []
    private var runtime: [AccountID: AccountRuntime] = [:]
    private var activeID: AccountID?
    /// crossPlan 판정에만 쓴다. 활성이 바뀔 때 직전 값을 남긴다.
    private var previousActiveID: AccountID?
    /// 마지막 선택이 풀 소진이었는가. 조건 계산의 입력이다.
    private var poolExhausted = false

    private var subscribers: [UUID: AsyncStream<RouterSnapshot>.Continuation] = [:]
    private var lastEmitted: RouterSnapshot?
    private var flushScheduled = false

    public init(clock: any Clock, coalesce: Duration = .milliseconds(100)) {
        self.clock = clock
        self.coalesce = coalesce
    }

    /// 시작 시퀀스에서 부른다. 저장된 런타임을 그대로 물려받는다.
    ///
    /// 재시작마다 잃으면 소진된 (조직, 모델) 쌍을 다시 프로브해 429 캐스케이드를
    /// 반복한다. docs/design/02-domain-model.md 6절
    public func load(accounts: [AccountID: Account], priority: [AccountID],
                     runtime: [AccountID: AccountRuntime]) {
        self.accounts = accounts
        self.priority = priority.filter { accounts[$0] != nil }
        self.runtime = runtime
        self.activeID = nil
        self.previousActiveID = nil
        self.poolExhausted = false
        scheduleEmit()
    }

    /// 값 타입 깊은 복사.
    public func snapshot() -> RouterSnapshot { currentSnapshot() }

    /// 종료 시퀀스와 debounce 저장이 읽는다. 파일 쓰기는 Router 의 일이 아니다.
    public func runtimeForPersistence() -> [AccountID: AccountRuntime] { runtime }

    public func select(
        model: ModelID,
        tried: Set<AccountID>,
        isConversationStart: Bool
    ) -> SelectionResult {
        let result = ClfCore.select(SelectionInput(
            priority: priority, accounts: accounts, runtime: runtime,
            model: model, now: clock.now, tried: tried,
            activeID: activeID, isConversationStart: isConversationStart))

        // 활성은 선택의 결과지 입력이 아니다
        switch result {
        case .selected(let selection):
            if selection.accountID != activeID { previousActiveID = activeID }
            activeID = selection.accountID
            poolExhausted = false
        case .exhausted:
            poolExhausted = true
        case .wait:
            break
        }

        scheduleEmit()
        return result
    }

    /// 같은 판정을 하되 후보별 이유를 함께 낸다. 컨트롤 플레인이 읽는다.
    ///
    /// 활성 조직을 바꾸지 않는다. 관찰이 상태를 움직이면 그 관찰은 거짓말이다.
    public func explain(model: ModelID, tried: Set<AccountID> = [],
                        isConversationStart: Bool = false) -> SelectionExplanation {
        ClfCore.explain(SelectionInput(
            priority: priority, accounts: accounts, runtime: runtime,
            model: model, now: clock.now, tried: tried,
            activeID: activeID, isConversationStart: isConversationStart))
    }

    public func apply(_ outcome: RoutingOutcome, to id: AccountID) {
        guard accounts[id] != nil else { return }
        var entry = runtime[id] ?? AccountRuntime()
        ClfCore.apply(outcome, to: &entry, now: clock.now)
        runtime[id] = entry
        if case .success = outcome { poolExhausted = false }
        scheduleEmit()
    }

    /// 100ms 단위로 합쳐 내보낸다. 요청이 몰리면 스냅샷이 초당 수십 번 나오는데
    /// 메뉴바는 그렇게 자주 다시 그릴 이유가 없다.
    public nonisolated var changes: AsyncStream<RouterSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id, continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(id) }
            }
        }
    }

    // MARK: 내부

    /// 붙는 즉시 현재 상태를 한 번 준다. 그러지 않으면 메뉴바가 첫 변경이
    /// 올 때까지 빈 채로 있는다.
    ///
    /// 이것도 마지막으로 내보낸 값으로 친다. 그러지 않으면 예약돼 있던 방출이
    /// 같은 내용을 한 번 더 흘려 구독자가 중복을 본다.
    private func subscribe(_ id: UUID, _ continuation: AsyncStream<RouterSnapshot>.Continuation) {
        subscribers[id] = continuation
        let snapshot = currentSnapshot()
        lastEmitted = snapshot
        continuation.yield(snapshot)
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    private func scheduleEmit() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [coalesce] in
            try? await Task.sleep(for: coalesce)
            self.emit()
        }
    }

    private func emit() {
        flushScheduled = false
        let snapshot = currentSnapshot()
        // 같은 값이 반복해서 흐르면 UI 가 헛돈다
        guard snapshot != lastEmitted else { return }
        lastEmitted = snapshot
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    private func currentSnapshot() -> RouterSnapshot {
        RouterSnapshot(
            accounts: priority.compactMap { accounts[$0] },
            priority: priority,
            runtime: runtime,
            activeID: activeID,
            conditions: currentConditions())
    }

    /// 조건은 상태에서 매번 파생시킨다. 저장하면 참이 아니게 된 뒤에도 남는다.
    /// 시간 기반 dedupe 를 두지 않는 이유이기도 하다.
    /// docs/design/02-domain-model.md 5절
    private func currentConditions() -> Set<Condition> {
        var conditions: Set<Condition> = []
        let now = clock.now

        for (id, entry) in runtime where entry.invalidatedAt != nil {
            guard accounts[id] != nil else { continue }
            conditions.insert(.accountInvalid(id))
        }

        if !accounts.isEmpty, accounts.values.allSatisfy({ !$0.autoSwitch }) {
            conditions.insert(.autoSwitchAllDisabled)
        }
        if poolExhausted { conditions.insert(.poolExhausted) }

        // 플랜이 바뀌면 캐시가 통째로 날아간다. 사용자가 알아야 하는 사실이다
        if let activeID, let active = accounts[activeID],
           let from = previousActiveID, from != activeID,
           let previous = accounts[from], previous.plan != active.plan {
            conditions.insert(.crossPlanActive(from: from, to: activeID))
        }

        // 1년짜리 토큰은 만료를 미리 알려야 한다. 갱신 경로가 없기 때문이다
        for (id, account) in accounts where account.credentialKind == .longLived {
            let expiresAt = account.tokenCreatedAt.addingTimeInterval(longLivedTokenLifetime)
            let daysLeft = Int(expiresAt.timeIntervalSince(now) / 86_400)
            if daysLeft <= tokenExpiryWarningDays {
                conditions.insert(.tokenExpiringSoon(id, daysLeft: max(0, daysLeft)))
            }
        }
        return conditions
    }
}
