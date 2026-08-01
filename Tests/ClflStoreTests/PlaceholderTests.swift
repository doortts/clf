import XCTest
@testable import ClflStore

final class ClaudeSettingsTests: XCTestCase {
    /// 사용자의 hooks, statusLine, permissions, model 을 절대 잃지 않는다.
    func test_installPreservesUnknownKeys() throws { throw XCTSkip("미구현") }
    func test_installCreatesBackupBeforeFirstWrite() throws { throw XCTSkip("미구현") }
    func test_installRefusesWhenAnotherValuePresent() throws { throw XCTSkip("미구현") }

    /// 앱을 끄면 Claude Code 가 고장 나는 것이 아니라 원래대로 돌아가야 한다.
    func test_uninstallRemovesOnlyOurKeys() throws { throw XCTSkip("미구현") }

    /// 사용자가 꺼진 것을 눈치채고 설정을 뒤지게 만들면 진 것이다.
    func test_enableToolSearchIsWrittenByDefault() throws { throw XCTSkip("미구현") }
}

final class RuntimeFileTests: XCTestCase {
    func test_atomicReplaceOnWrite() throws { throw XCTSkip("미구현") }
    func test_corruptFileLoadsAsEmptyWithoutThrowing() throws { throw XCTSkip("미구현") }
    func test_prunesCooldownsOlderThanSevenDays() throws { throw XCTSkip("미구현") }
}
