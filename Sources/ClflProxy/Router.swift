import Foundation
import ClflCore

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

    public init(clock: any Clock) { _ = clock; fatalError("TODO") }

    /// 값 타입 깊은 복사.
    public func snapshot() -> RouterSnapshot { fatalError("TODO") }

    public func select(
        model: ModelID,
        tried: Set<AccountID>,
        isConversationStart: Bool
    ) -> SelectionResult {
        _ = (model, tried, isConversationStart)
        fatalError("TODO")
    }

    public func apply(_ outcome: RoutingOutcome, to id: AccountID) {
        _ = (outcome, id)
        fatalError("TODO")
    }

    /// 100ms 단위로 합쳐 내보낸다. 요청이 몰리면 스냅샷이 초당 수십 번 나오는데
    /// 메뉴바는 그렇게 자주 다시 그릴 이유가 없다.
    public nonisolated var changes: AsyncStream<RouterSnapshot> { fatalError("TODO") }
}
