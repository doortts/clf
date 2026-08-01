import XCTest
@testable import ClflCore

/// docs/design/02-domain-model.md 3절
final class SelectionTests: XCTestCase {

    func test_skipsAutoSwitchDisabledAccounts() throws { throw XCTSkip("미구현") }
    func test_skipsInvalidAccounts() throws { throw XCTSkip("미구현") }
    func test_skipsAccountWideCooldown() throws { throw XCTSkip("미구현") }

    /// 같은 조직이 한 모델에는 cooling 이고 다른 모델에는 ready 일 수 있다.
    func test_modelCooldownDoesNotBlockOtherModels() throws { throw XCTSkip("미구현") }

    func test_doesNotReselectAlreadyTriedAccountInSameRequest() throws { throw XCTSkip("미구현") }

    /// 일시 과부하와 진짜 소진이 같은 경로로 흐르면 시작 시 풀 전체가 암전된다.
    func test_waitWhenRecoverableVersusExhaustedWhenNot() throws { throw XCTSkip("미구현") }

    /// 뺀 이유를 배신하지 않기 위해 끌어다 쓰지 않되, 무엇을 켜면 풀리는지는 알려준다.
    func test_exhaustedCarriesUnblockableAccounts() throws { throw XCTSkip("미구현") }

    // MARK: 선제 강등

    /// 전 조직이 임계값을 넘어도 가용 조직이 0이 되면 안 된다.
    func test_proactiveDemotesRatherThanExcludes() throws { throw XCTSkip("미구현") }

    func test_proactiveOnlyAppliesAtConversationStart() throws { throw XCTSkip("미구현") }

    /// 읽기 없는 후보는 제외가 아니라 tier 1. CCSwitcher 와 다른 선택이다.
    func test_unknownHeadroomGoesToTier1NotExcluded() throws { throw XCTSkip("미구현") }
}

final class HeadroomTests: XCTestCase {

    /// 5시간만 보면 7일이 먼저 바닥나는 경우를 통째로 놓친다.
    func test_bindingIsMinAcrossFiveHourAndWeekly() throws { throw XCTSkip("미구현") }

    /// 모델별 주간이 셋째 축이다. Usage API 가 있을 때만 채워진다.
    func test_bindingIncludesModelWeeklyWhenPresent() throws { throw XCTSkip("미구현") }

    func test_degradesToTwoWindowsWhenModelWeeklyAbsent() throws { throw XCTSkip("미구현") }

    /// 창이 리셋됐으면 스냅샷이 말하는 소비는 존재하지 않는다.
    func test_discardsWindowWhoseResetHasPassed() throws { throw XCTSkip("미구현") }

    /// 활성 판단은 strict. 만료를 모르는 묵은 낮은 값이 강등을 유발하면 안 된다.
    func test_requireKnownResetStrictForActive() throws { throw XCTSkip("미구현") }

    /// 후보 판단은 lenient. 묵은 낮은 값은 그 후보를 뒤로 밀 뿐이다.
    func test_requireKnownResetLenientForCandidate() throws { throw XCTSkip("미구현") }

    // MARK: 밴드 경계값

    func test_band_boundaries() throws {
        throw XCTSkip("미구현: 4.9 / 5.0 / 14.9 / 15.0 / 49.9 / 50.0")
    }
}

final class ShortCodeTests: XCTestCase {
    func test_teamAccountsGetSequentialCodesByAlphabeticalOrder() throws { throw XCTSkip("미구현") }
    func test_nonTeamAccountsUseFirstTwoLettersUppercased() throws { throw XCTSkip("미구현") }
    func test_collidingPrefixesFallBackToFirstLetterPlusOrdinal() throws { throw XCTSkip("미구현") }

    /// 조직을 추가하면 기존 코드가 밀린다. 알려진 성질이므로 명시적으로 잠근다.
    func test_addingAccountRenumbersLaterCodes() throws { throw XCTSkip("미구현") }

    func test_mostRecentOtherExcludesActive() throws { throw XCTSkip("미구현") }
}
