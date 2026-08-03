import XCTest
import ClfCore
@testable import ClfProxy

private let T0 = Date(timeIntervalSince1970: 1_700_000_000)
private func at(_ o: TimeInterval) -> Date { T0.addingTimeInterval(o) }

private func acct(_ id: String, plan: Plan = .team, autoSwitch: Bool = true) -> Account {
    Account(id: id, plan: plan, autoSwitch: autoSwitch, credentialKind: .oauth,
            tokenCreatedAt: T0, tokenFingerprint: "fp-\(id)")
}

/// 시각을 테스트가 쥔다. 쿨다운 경계는 시각으로만 표현된다.
final class MovableClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date = T0) { _now = now }
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); _now = _now.addingTimeInterval(seconds); lock.unlock()
    }
}

/// 런타임 상태의 유일한 가변 소유자.
/// docs/design/01-architecture.md 3절, 04-implementation.md 4절
final class RouterTests: XCTestCase {

    var clock: MovableClock!
    var router: Router!

    override func setUp() async throws {
        clock = MovableClock()
        router = Router(clock: clock, coalesce: .milliseconds(5))
        await router.load(accounts: ["a": acct("a"), "b": acct("b"), "c": acct("c")],
                          priority: ["a", "b", "c"], runtime: [:])
    }

    func pick(_ tried: Set<AccountID> = [], start: Bool = false) async -> AccountID? {
        if case .selected(let s) = await router.select(model: "m", tried: tried,
                                                       isConversationStart: start) {
            return s.accountID
        }
        return nil
    }

    // MARK: 선택

    func test_selectsInPriorityOrder() async {
        let picked = await pick()
        XCTAssertEqual(picked, "a")
    }

    func test_appliedCooldownMovesSelectionOn() async {
        await router.apply(.rateLimited(model: "m", until: at(600), transient: false), to: "a")
        let picked = await pick()
        XCTAssertEqual(picked, "b")
    }

    /// 쿨다운이 풀리면 원래 순서로 돌아온다. 상태가 아니라 시각의 함수다.
    func test_cooldownExpiresWithTime() async {
        await router.apply(.rateLimited(model: "m", until: at(600), transient: false), to: "a")
        var picked = await pick()
        XCTAssertEqual(picked, "b")

        clock.advance(601)
        picked = await pick()
        XCTAssertEqual(picked, "a")
    }

    /// 429 는 우리 판단이 아니라 서버의 사실 통보다. 최신 값이 이긴다.
    func test_laterCooldownOverwritesEarlier() async {
        await router.apply(.rateLimited(model: "m", until: at(60), transient: false), to: "a")
        await router.apply(.rateLimited(model: "m", until: at(600), transient: false), to: "a")
        clock.advance(61)
        let picked = await pick()
        XCTAssertEqual(picked, "b", "나중 값 600 이 살아 있어야 한다")
    }

    func test_invalidationSurvivesTime() async {
        await router.apply(.invalidated, to: "a")
        clock.advance(86_400)
        let picked = await pick()
        XCTAssertEqual(picked, "b", "시간으로 회복되지 않는다")
    }

    /// 성공은 자격증명이 살아있다는 뜻이다.
    func test_successClearsInvalidation() async {
        await router.apply(.invalidated, to: "a")
        await router.apply(.success(usage: nil, rateLimit: nil), to: "a")
        let picked = await pick()
        XCTAssertEqual(picked, "a")
    }

    // MARK: 활성 조직

    /// 활성은 선택의 결과지 입력이 아니다. 고른 순간 정해진다.
    func test_selectionSetsActive() async {
        _ = await pick()
        let snapshot = await router.snapshot()
        XCTAssertEqual(snapshot.activeID, "a")
    }

    func test_activeFollowsSwap() async {
        _ = await pick()
        await router.apply(.rateLimited(model: "m", until: at(600), transient: false), to: "a")
        _ = await pick()
        let snapshot = await router.snapshot()
        XCTAssertEqual(snapshot.activeID, "b")
    }

    // MARK: 스냅샷

    /// UI 로 넘어가는 값 타입 깊은 복사. 토큰은 절대 싣지 않는다.
    func test_snapshotCarriesAccountsAndRuntime() async {
        await router.apply(.rateLimited(model: "m", until: at(600), transient: false), to: "a")
        let snapshot = await router.snapshot()
        XCTAssertEqual(snapshot.priority, ["a", "b", "c"])
        XCTAssertEqual(Set(snapshot.accounts.map(\.id)), ["a", "b", "c"])
        XCTAssertEqual(snapshot.runtime["a"]?.modelCooldowns["m"], at(600))
    }

    /// 이후 변경이 이미 넘긴 스냅샷을 건드리면 UI 가 찢어진 상태를 그린다.
    func test_snapshotIsADeepCopy() async {
        let before = await router.snapshot()
        await router.apply(.invalidated, to: "a")
        XCTAssertNil(before.runtime["a"]?.invalidatedAt)
    }

    // MARK: 지속 조건

    func test_poolExhaustedCondition() async {
        for id in ["a", "b", "c"] { await router.apply(.invalidated, to: id) }
        _ = await router.select(model: "m", tried: [], isConversationStart: false)
        let snapshot = await router.snapshot()
        XCTAssertTrue(snapshot.conditions.contains(.poolExhausted))
    }

    func test_invalidAccountCondition() async {
        await router.apply(.invalidated, to: "b")
        let snapshot = await router.snapshot()
        XCTAssertTrue(snapshot.conditions.contains(.accountInvalid("b")))
    }

    /// 자동 전환 대상이 0개면 모든 요청이 실패한다. 그 사실을 말해야 한다.
    func test_autoSwitchAllDisabledCondition() async {
        await router.load(accounts: ["a": acct("a", autoSwitch: false)],
                          priority: ["a"], runtime: [:])
        let snapshot = await router.snapshot()
        XCTAssertTrue(snapshot.conditions.contains(.autoSwitchAllDisabled))
    }

    /// 조건은 참인 동안 계속 보인다. 시간 기반 dedupe 를 두지 않는다.
    func test_conditionClearsWhenNoLongerTrue() async {
        await router.apply(.invalidated, to: "b")
        var snapshot = await router.snapshot()
        XCTAssertTrue(snapshot.conditions.contains(.accountInvalid("b")))

        await router.apply(.success(usage: nil, rateLimit: nil), to: "b")
        snapshot = await router.snapshot()
        XCTAssertFalse(snapshot.conditions.contains(.accountInvalid("b")))
    }

    func test_crossPlanConditionWhenSwappingBetweenPlans() async {
        await router.load(accounts: ["a": acct("a", plan: .team),
                                     "e": acct("e", plan: .enterprise)],
                          priority: ["a", "e"], runtime: [:])
        _ = await pick()
        await router.apply(.rateLimited(model: "m", until: at(600), transient: false), to: "a")
        _ = await pick()

        let snapshot = await router.snapshot()
        XCTAssertTrue(snapshot.conditions.contains(.crossPlanActive(from: "a", to: "e")))
    }

    // MARK: 변경 구독

    /// 붙는 즉시 현재 상태를 준다. 그러지 않으면 메뉴바가 첫 변경이 올 때까지
    /// 빈 채로 있는다.
    func test_subscriberGetsCurrentStateImmediately() async {
        let router = self.router!
        var iterator = router.changes.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.priority, ["a", "b", "c"])
    }

    /// 요청이 몰리면 스냅샷이 초당 수십 번 나온다. 메뉴바는 그렇게 자주 다시
    /// 그릴 이유가 없다.
    func test_changesEmitsAfterMutation() async throws {
        let router = self.router!
        var iterator = router.changes.makeAsyncIterator()
        _ = await iterator.next()                       // 붙을 때 오는 현재 상태

        Task {
            try? await Task.sleep(for: .milliseconds(20))
            await router.apply(.invalidated, to: "a")
        }
        let snapshot = await iterator.next()
        XCTAssertNotNil(snapshot?.runtime["a"]?.invalidatedAt)
    }

    /// 같은 값이 반복해서 흐르면 UI 가 헛돈다. 두 번째 apply 는 결과가 같으므로
    /// 아무것도 내보내지 않아야 하고, 그래서 다음에 잡히는 것은 b 의 변화다.
    func test_changesSkipsIdenticalSnapshots() async throws {
        let router = self.router!
        var iterator = router.changes.makeAsyncIterator()
        _ = await iterator.next()
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            await router.apply(.invalidated, to: "a")
            try? await Task.sleep(for: .milliseconds(30))
            await router.apply(.invalidated, to: "a")   // 같은 결과. 조용해야 한다
            try? await Task.sleep(for: .milliseconds(30))
            await router.apply(.invalidated, to: "b")
        }
        let first = await iterator.next()
        XCTAssertNotNil(first?.runtime["a"]?.invalidatedAt)
        XCTAssertNil(first?.runtime["b"]?.invalidatedAt)

        let second = await iterator.next()
        XCTAssertNotNil(second?.runtime["b"]?.invalidatedAt)
    }

    /// 창 안의 변경은 하나로 합친다. 요청이 몰려도 메뉴바는 초당 몇 번만 그린다.
    func test_changesCoalescesBurstIntoOne() async throws {
        let router = self.router!
        var iterator = router.changes.makeAsyncIterator()
        _ = await iterator.next()
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            await router.apply(.invalidated, to: "a")
            await router.apply(.invalidated, to: "b")
            await router.apply(.invalidated, to: "c")
        }
        let merged = await iterator.next()
        XCTAssertNotNil(merged?.runtime["a"]?.invalidatedAt)
        XCTAssertNotNil(merged?.runtime["b"]?.invalidatedAt)
        XCTAssertNotNil(merged?.runtime["c"]?.invalidatedAt, "셋이 한 번에 온다")
    }

    // MARK: 영속화

    /// 재시작마다 잃으면 소진된 쌍을 다시 프로브해 429 캐스케이드를 반복한다.
    func test_loadRestoresRuntime() async {
        let saved: [AccountID: AccountRuntime] = [
            "a": AccountRuntime(invalidatedAt: at(-100)),
            "b": AccountRuntime(modelCooldowns: ["m": at(600)]),
        ]
        await router.load(accounts: ["a": acct("a"), "b": acct("b"), "c": acct("c")],
                          priority: ["a", "b", "c"], runtime: saved)
        let picked = await pick()
        XCTAssertEqual(picked, "c", "a 는 무효, b 는 쿨다운")
    }

    /// 저장할 값을 밖으로 낸다. 파일 쓰기는 Router 의 일이 아니다.
    func test_exportsRuntimeForPersistence() async {
        await router.apply(.invalidated, to: "a")
        let runtime = await router.runtimeForPersistence()
        XCTAssertEqual(runtime["a"]?.invalidatedAt, T0)
    }
}
