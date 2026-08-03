import XCTest
@testable import ClfDesktop

/// 로그인 항목 상태를 사람이 읽는 말로 옮긴다.
///
/// `SMAppService` 는 흉내내기 어렵다. 그래서 상태를 우리 열거형으로 받아
/// 그다음 판단만 여기서 잠근다.
final class LoginItemStateTests: XCTestCase {

    func test_everyStateSaysSomething() {
        for state in LoginItemState.allCases {
            XCTAssertFalse(state.label.isEmpty, "\(state)")
        }
    }

    /// 체크박스가 켜져 보여야 하는 상태는 하나뿐이다.
    /// 승인 대기 중을 켜진 것으로 그리면 다음 부팅에 안 뜨고 사용자는 모른다.
    func test_onlyEnabledLooksOn() {
        XCTAssertTrue(LoginItemState.on.isChecked)
        XCTAssertFalse(LoginItemState.needsApproval.isChecked)
        XCTAssertFalse(LoginItemState.off.isChecked)
        XCTAssertFalse(LoginItemState.unavailable.isChecked)
    }

    /// 사용자가 할 일이 남았으면 그게 무엇인지 말한다.
    func test_statesThatNeedTheUserExplainWhat() {
        XCTAssertNotNil(LoginItemState.needsApproval.hint)
        XCTAssertTrue(LoginItemState.needsApproval.hint!.contains("시스템 설정"))
        XCTAssertNotNil(LoginItemState.unavailable.hint)
    }

    /// 다 잘 되고 있으면 잔소리하지 않는다.
    func test_settledStatesAreQuiet() {
        XCTAssertNil(LoginItemState.on.hint)
        XCTAssertNil(LoginItemState.off.hint)
    }

    /// 켤 수 없는 상태에서 체크박스를 살려두면 눌러도 아무 일이 없다.
    func test_unavailableCannotBeToggled() {
        XCTAssertFalse(LoginItemState.unavailable.isToggleable)
        XCTAssertTrue(LoginItemState.off.isToggleable)
        XCTAssertTrue(LoginItemState.on.isToggleable)
        // 승인 대기 중에는 끌 수 있어야 한다. 취소할 길을 막으면 안 된다
        XCTAssertTrue(LoginItemState.needsApproval.isToggleable)
    }
}

/// 빌드 디렉토리에서 실행하면 로그인 항목이 다음 빌드에 깨진다.
final class BundleLocationTests: XCTestCase {

    func test_buildDirectoryIsNotAHome() {
        XCTAssertFalse(LoginItemState.isStableLocation("/Users/x/repos/clf/.build/clf.app"))
    }

    func test_applicationsFoldersAreFine() {
        XCTAssertTrue(LoginItemState.isStableLocation("/Applications/clf.app"))
        XCTAssertTrue(LoginItemState.isStableLocation("/Users/x/Applications/clf.app"))
    }

    /// 개발 중에는 여기서 돈다. 승인을 받아도 다음 make-app.sh 에 사라진다.
    func test_derivedDataIsNotAHome() {
        XCTAssertFalse(LoginItemState.isStableLocation(
            "/Users/x/Library/Developer/Xcode/DerivedData/clf-abc/Build/Products/Debug/clf.app"))
    }
}

/// `SMAppService.Status` 를 우리 상태로 옮기는 규칙.
///
/// 실측으로 잡은 것이 하나 있다. 한 번도 등록한 적이 없으면 `.notRegistered`
/// 가 아니라 **`.notFound`(3) 를 준다.** 그걸 "등록 불가" 로 읽으면 체크박스가
/// 처음부터 꺼진 채 잠긴다. 아무도 이 기능을 못 쓴다.
final class LoginItemMappingTests: XCTestCase {
    let home = "/Users/x/Applications/clf.app"

    func test_neverRegisteredIsJustOff() {
        XCTAssertEqual(LoginItemState.from(statusRawValue: 3, path: home), .off)
    }

    func test_registeredStates() {
        XCTAssertEqual(LoginItemState.from(statusRawValue: 0, path: home), .off)
        XCTAssertEqual(LoginItemState.from(statusRawValue: 1, path: home), .on)
        XCTAssertEqual(LoginItemState.from(statusRawValue: 2, path: home), .needsApproval)
    }

    /// 자리가 잘못됐으면 시스템에 묻기 전에 걸러낸다. 등록이 되더라도 다음
    /// 빌드에 번들이 사라져 헛일이다.
    func test_locationLosesToNothing() {
        for raw in 0...3 {
            XCTAssertEqual(
                LoginItemState.from(statusRawValue: raw, path: "/Users/x/repos/clf/.build/clf.app"),
                .unavailable, "raw=\(raw)")
        }
    }

    /// 모르는 값이 오면 켜진 것처럼 그리지 않는다.
    func test_unknownStatusIsNotOn() {
        XCTAssertNotEqual(LoginItemState.from(statusRawValue: 99, path: home), .on)
    }
}
