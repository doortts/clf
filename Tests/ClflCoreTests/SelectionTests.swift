import XCTest
@testable import ClflCore

private let T0 = Date(timeIntervalSince1970: 1_700_000_000)
private func at(_ offset: TimeInterval) -> Date { T0.addingTimeInterval(offset) }

private func acct(_ id: String, plan: Plan = .team, autoSwitch: Bool = true) -> Account {
    Account(id: id, plan: plan, autoSwitch: autoSwitch, credentialKind: .oauth,
            tokenCreatedAt: T0, tokenFingerprint: "fp-\(id)")
}
private func snap(_ h5: Double?, _ d7: Double? = nil, model: (ModelID, Double)? = nil,
                  reset: Date? = at(3600)) -> RateLimitSnapshot {
    var s = RateLimitSnapshot(observedAt: T0, source: .usageAPI)
    if let h5 { s.fiveHour = Window(usedRatio: 1 - h5, resetsAt: reset) }
    if let d7 { s.sevenDayAll = Window(usedRatio: 1 - d7, resetsAt: reset) }
    if let model { s.modelWeekly[model.0] = Window(usedRatio: 1 - model.1, resetsAt: reset) }
    return s
}

/// docs/design/02-domain-model.md 3절
final class SelectionTests: XCTestCase {

    let model = "claude-opus-4-5"

    func input(_ priority: [String],
               accounts: [Account],
               runtime: [AccountID: AccountRuntime] = [:],
               tried: Set<AccountID> = [],
               activeID: AccountID? = nil,
               start: Bool = false) -> SelectionInput {
        SelectionInput(priority: priority,
                       accounts: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) }),
                       runtime: runtime, model: model, now: T0,
                       tried: tried, activeID: activeID, isConversationStart: start)
    }
    func picked(_ r: SelectionResult) -> AccountID? {
        if case .selected(let s) = r { return s.accountID }
        return nil
    }

    func test_picksHighestPriorityReadyAccount() {
        let r = select(input(["a", "b"], accounts: [acct("a"), acct("b")]))
        XCTAssertEqual(picked(r), "a")
    }

    func test_skipsAutoSwitchDisabledAccounts() {
        let r = select(input(["a", "b"], accounts: [acct("a", autoSwitch: false), acct("b")]))
        XCTAssertEqual(picked(r), "b")
    }

    func test_skipsInvalidAccounts() {
        let rt = ["a": AccountRuntime(invalidatedAt: T0)]
        let r = select(input(["a", "b"], accounts: [acct("a"), acct("b")], runtime: rt))
        XCTAssertEqual(picked(r), "b")
    }

    func test_skipsAccountWideCooldown() {
        let rt = ["a": AccountRuntime(accountCooldownUntil: at(600))]
        let r = select(input(["a", "b"], accounts: [acct("a"), acct("b")], runtime: rt))
        XCTAssertEqual(picked(r), "b")
    }

    /// 같은 조직이 한 모델에는 cooling 이고 다른 모델에는 ready 일 수 있다.
    func test_modelCooldownDoesNotBlockOtherModels() {
        let rt = ["a": AccountRuntime(modelCooldowns: ["fable": at(600)])]
        XCTAssertEqual(picked(select(input(["a"], accounts: [acct("a")], runtime: rt))), "a",
                       "다른 모델 요청은 통과해야 한다")

        let blocked = SelectionInput(priority: ["a"], accounts: ["a": acct("a")],
                                     runtime: rt, model: "fable", now: T0)
        guard case .wait(let until) = select(blocked) else {
            return XCTFail("fable 은 쿨다운이라 wait 여야 한다")
        }
        XCTAssertEqual(until, at(600))
    }

    func test_doesNotReselectAlreadyTriedAccountInSameRequest() {
        let r = select(input(["a", "b"], accounts: [acct("a"), acct("b")], tried: ["a"]))
        XCTAssertEqual(picked(r), "b")
    }

    /// 일시 과부하와 진짜 소진이 같은 경로로 흐르면 시작 시 풀 전체가 암전된다.
    func test_waitWhenRecoverableVersusExhaustedWhenNot() {
        let cooling = ["a": AccountRuntime(accountCooldownUntil: at(300)),
                       "b": AccountRuntime(accountCooldownUntil: at(120))]
        guard case .wait(let until) = select(input(["a", "b"],
                accounts: [acct("a"), acct("b")], runtime: cooling)) else {
            return XCTFail("회복 가능하면 wait")
        }
        XCTAssertEqual(until, at(120), "가장 이른 해제 시각")

        let dead = ["a": AccountRuntime(invalidatedAt: T0), "b": AccountRuntime(invalidatedAt: T0)]
        guard case .exhausted = select(input(["a", "b"],
                accounts: [acct("a"), acct("b")], runtime: dead)) else {
            return XCTFail("전부 invalid 면 exhausted")
        }
    }

    /// 뺀 이유를 배신하지 않기 위해 끌어다 쓰지 않되, 무엇을 켜면 풀리는지는 알려준다.
    func test_exhaustedCarriesUnblockableAccounts() {
        let rt = ["a": AccountRuntime(invalidatedAt: T0)]
        let r = select(input(["a", "paused"],
                             accounts: [acct("a"), acct("paused", autoSwitch: false)], runtime: rt))
        XCTAssertEqual(r, .exhausted(unblockable: ["paused"]))
    }

    func test_unblockableExcludesAccountsThatAreThemselvesUnusable() {
        let rt = ["a": AccountRuntime(invalidatedAt: T0),
                  "paused": AccountRuntime(invalidatedAt: T0)]
        let r = select(input(["a", "paused"],
                             accounts: [acct("a"), acct("paused", autoSwitch: false)], runtime: rt))
        XCTAssertEqual(r, .exhausted(unblockable: []))
    }

    func test_crossPlanFlagSetWhenPlanDiffersFromActive() {
        let r = select(input(["ent"], accounts: [acct("ent", plan: .enterprise), acct("t", plan: .team)],
                             activeID: "t"))
        guard case .selected(let s) = r else { return XCTFail() }
        XCTAssertTrue(s.isCrossPlan)
    }

    // MARK: 선제 강등

    /// 전 조직이 임계값을 넘어도 가용 조직이 0이 되면 안 된다.
    func test_proactiveDemotesRatherThanExcludes() {
        let rt = ["a": AccountRuntime(rateLimit: snap(0.02)),
                  "b": AccountRuntime(rateLimit: snap(0.03))]
        let r = select(input(["a", "b"], accounts: [acct("a"), acct("b")],
                             runtime: rt, start: true))
        XCTAssertEqual(picked(r), "a", "전부 tier 1 이어도 최상위를 고른다")
    }

    func test_proactivePrefersAccountAboveCeiling() {
        // 임계값 0.15 + hysteresis 0.10 = 0.25 이상이라야 tier 0
        let rt = ["a": AccountRuntime(rateLimit: snap(0.20)),
                  "b": AccountRuntime(rateLimit: snap(0.40))]
        let r = select(input(["a", "b"], accounts: [acct("a"), acct("b")],
                             runtime: rt, start: true))
        XCTAssertEqual(picked(r), "b", "a 는 25% 아래라 tier 1 로 밀린다")
    }

    func test_proactiveOnlyAppliesAtConversationStart() {
        let rt = ["a": AccountRuntime(rateLimit: snap(0.20)),
                  "b": AccountRuntime(rateLimit: snap(0.40))]
        let r = select(input(["a", "b"], accounts: [acct("a"), acct("b")],
                             runtime: rt, start: false))
        XCTAssertEqual(picked(r), "a", "대화 도중에는 강등하지 않는다")
    }

    /// 읽기 없는 후보는 제외가 아니라 tier 1. CCSwitcher 와 다른 선택이다.
    func test_unknownHeadroomGoesToTier1NotExcluded() {
        let rt = ["b": AccountRuntime(rateLimit: snap(0.90))]
        let r = select(input(["a", "b"], accounts: [acct("a"), acct("b")],
                             runtime: rt, start: true))
        XCTAssertEqual(picked(r), "b", "읽기 있는 b 가 앞선다")

        // 읽기 없는 조직만 남아도 선택은 된다
        let only = select(input(["a"], accounts: [acct("a")], start: true))
        XCTAssertEqual(picked(only), "a")
    }
}

final class HeadroomTests: XCTestCase {
    let model = "fable"

    /// 5시간만 보면 주간이 먼저 바닥나는 경우를 통째로 놓친다.
    func test_bindingIsMinAcrossFiveHourAndWeekly() {
        let s = snap(0.53, 0.41)
        XCTAssertEqual(bindingHeadroom(s, for: model, now: T0, requireKnownReset: false)!,
                       0.41, accuracy: 1e-9)
    }

    /// 모델별 주간이 셋째 축이다. Usage API 가 있을 때만 채워진다.
    func test_bindingIncludesModelWeeklyWhenPresent() {
        let s = snap(0.53, 0.41, model: (model, 0.0))
        XCTAssertEqual(bindingHeadroom(s, for: model, now: T0, requireKnownReset: false)!,
                       0.0, accuracy: 1e-9)
    }

    func test_modelWeeklyOfOtherModelIsIgnored() {
        let s = snap(0.53, 0.41, model: ("other", 0.0))
        XCTAssertEqual(bindingHeadroom(s, for: model, now: T0, requireKnownReset: false)!,
                       0.41, accuracy: 1e-9)
    }

    func test_degradesToTwoWindowsWhenModelWeeklyAbsent() {
        let s = snap(0.80, 0.60)
        XCTAssertEqual(bindingHeadroom(s, for: model, now: T0, requireKnownReset: false)!,
                       0.60, accuracy: 1e-9)
    }

    /// 창이 리셋됐으면 스냅샷이 말하는 소비는 존재하지 않는다.
    func test_discardsWindowWhoseResetHasPassed() {
        var s = snap(0.10, 0.90)
        s.fiveHour = Window(usedRatio: 0.90, resetsAt: at(-10))   // 이미 지났다
        XCTAssertEqual(bindingHeadroom(s, for: model, now: T0, requireKnownReset: false)!,
                       0.90, accuracy: 1e-9)
    }

    func test_nilWhenAllWindowsExpired() {
        let s = snap(0.10, 0.20, reset: at(-10))
        XCTAssertNil(bindingHeadroom(s, for: model, now: T0, requireKnownReset: false))
    }

    /// 활성 판단은 strict. 만료를 모르는 묵은 낮은 값이 강등을 유발하면 안 된다.
    func test_requireKnownResetStrictForActive() {
        let s = snap(0.02, reset: nil)
        XCTAssertNil(bindingHeadroom(s, for: model, now: T0, requireKnownReset: true))
    }

    /// 후보 판단은 lenient. 묵은 낮은 값은 그 후보를 뒤로 밀 뿐이다.
    func test_requireKnownResetLenientForCandidate() {
        let s = snap(0.02, reset: nil)
        XCTAssertEqual(bindingHeadroom(s, for: model, now: T0, requireKnownReset: false)!,
                       0.02, accuracy: 1e-9)
    }

    func test_nilSnapshotYieldsNil() {
        XCTAssertNil(bindingHeadroom(nil, for: model, now: T0, requireKnownReset: false))
    }

    // MARK: 밴드 경계값

    func test_band_boundaries() {
        XCTAssertEqual(band(remaining: 0.049), .empty)
        XCTAssertEqual(band(remaining: 0.050), .low)
        XCTAssertEqual(band(remaining: 0.149), .low)
        XCTAssertEqual(band(remaining: 0.150), .normal)
        XCTAssertEqual(band(remaining: 0.499), .normal)
        XCTAssertEqual(band(remaining: 0.500), .ample)
    }

    /// 노랑 시작점은 선제 전환 임계값과 같은 값이어야 한다.
    func test_band_lowThresholdFollowsProactiveThreshold() {
        XCTAssertEqual(band(remaining: 0.20, lowThreshold: 0.25), .low)
        XCTAssertEqual(band(remaining: 0.20, lowThreshold: 0.15), .normal)
    }
}

final class CooldownTests: XCTestCase {
    func test_availabilityPrecedence() {
        var rt = AccountRuntime(invalidatedAt: T0, accountCooldownUntil: at(600))
        XCTAssertEqual(availability(rt, for: "m", now: T0, activeID: nil, id: "a"),
                       .invalid(since: T0), "invalid 가 쿨다운보다 앞선다")
        rt.invalidatedAt = nil
        XCTAssertEqual(availability(rt, for: "m", now: T0, activeID: nil, id: "a"),
                       .cooling(until: at(600), scope: .account))
    }

    func test_expiredCooldownBecomesReady() {
        let rt = AccountRuntime(accountCooldownUntil: at(-1))
        XCTAssertEqual(availability(rt, for: "m", now: T0, activeID: nil, id: "a"), .ready)
    }

    func test_activeWhenIdMatches() {
        XCTAssertEqual(availability(AccountRuntime(), for: "m", now: T0, activeID: "a", id: "a"),
                       .active)
    }

    func test_applyTransientUsesShortCooldown() {
        var rt = AccountRuntime()
        apply(.rateLimited(model: "m", until: at(3600), transient: true), to: &rt, now: T0)
        XCTAssertEqual(rt.modelCooldowns["m"], at(TimeInterval(transientCooldownSeconds)))
    }

    func test_applyNonTransientUsesServerReset() {
        var rt = AccountRuntime()
        apply(.rateLimited(model: "m", until: at(3600), transient: false), to: &rt, now: T0)
        XCTAssertEqual(rt.modelCooldowns["m"], at(3600))
    }

    /// 성공했다는 것은 자격증명이 살아있다는 뜻이다.
    func test_applySuccessClearsInvalidation() {
        var rt = AccountRuntime(invalidatedAt: at(-100))
        apply(.success(usage: nil, rateLimit: nil), to: &rt, now: T0)
        XCTAssertNil(rt.invalidatedAt)
        XCTAssertEqual(rt.lastUsedAt, T0)
    }

    func test_applyPassthroughChangesNothing() {
        var rt = AccountRuntime(lastUsedAt: at(-500))
        apply(.passthrough, to: &rt, now: T0)
        XCTAssertEqual(rt.lastUsedAt, at(-500))
    }
}

final class ShortCodeTests: XCTestCase {
    func test_teamAccountsGetSequentialCodesByAlphabeticalOrder() {
        XCTAssertEqual(shortCodes(for: ["team3", "team1", "team2"]),
                       ["team1": "T1", "team2": "T2", "team3": "T3"])
    }

    /// 번호는 이름 안의 숫자가 아니라 정렬 순서에서 나온다.
    func test_numberComesFromSortOrderNotFromName() {
        XCTAssertEqual(shortCodes(for: ["team1", "team7"]), ["team1": "T1", "team7": "T2"])
    }

    func test_nonTeamAccountsUseFirstTwoLettersUppercased() {
        XCTAssertEqual(shortCodes(for: ["ent1", "personal"]), ["ent1": "EN", "personal": "PE"])
    }

    func test_collidingPrefixesFallBackToFirstLetterPlusOrdinal() {
        XCTAssertEqual(shortCodes(for: ["ent1", "ent2"]), ["ent1": "E1", "ent2": "E2"])
    }

    func test_mixedTeamAndOther() {
        XCTAssertEqual(shortCodes(for: ["team40", "team52", "ent1"]),
                       ["team40": "T1", "team52": "T2", "ent1": "EN"])
    }

    /// 조직을 추가하면 기존 코드가 밀린다. 알려진 성질이므로 명시적으로 잠근다.
    func test_addingAccountRenumbersLaterCodes() {
        XCTAssertEqual(shortCodes(for: ["team1", "team3"])["team3"], "T2")
        XCTAssertEqual(shortCodes(for: ["team1", "team2", "team3"])["team3"], "T3")
    }

    func test_singleCharacterNameSurvives() {
        XCTAssertEqual(shortCodes(for: ["x"]), ["x": "X"])
    }

    func test_mostRecentOtherExcludesActive() {
        let rt: [AccountID: AccountRuntime] = [
            "a": AccountRuntime(lastUsedAt: at(100)),
            "b": AccountRuntime(lastUsedAt: at(200)),
            "c": AccountRuntime(),
        ]
        XCTAssertEqual(mostRecentOther(runtime: rt, activeID: "b"), "a")
        XCTAssertEqual(mostRecentOther(runtime: rt, activeID: "a"), "b")
    }

    func test_mostRecentOtherNilWhenNothingUsed() {
        XCTAssertNil(mostRecentOther(runtime: ["a": AccountRuntime()], activeID: nil))
    }
}
