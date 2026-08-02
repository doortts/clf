import XCTest
@testable import ClflDesktop

private func org(_ uuid: String, _ name: String, active: Bool = false) -> OrgUsage {
    OrgUsage(uuid: uuid, name: name, isActive: active, plan: "team", limits: [:])
}

/// 앞 창이 어느 계정 것인지. 메뉴바 밑줄이 이 답을 그린다.
/// docs/design/focus-underline-mockup.html
final class FocusMarkTests: XCTestCase {

    let orgs = [org("t40", "NAVER_TEAM_40", active: true),
                org("t52", "NAVER_TEAM_52")]
    let claude = AltInstance.executable

    /// 별도 인스턴스 창이 앞이면 그 계정이다.
    func test_altInstanceInFrontMarksItsAccount() {
        let uuid = FocusMark.focusedUUID(
            frontPid: 900, frontExecutable: claude,
            instances: ["NAVER_TEAM_52": 900],
            orgs: orgs, activeUUID: "t40")
        XCTAssertEqual(uuid, "t52")
    }

    /// 같은 실행 파일인데 pid 가 인스턴스 목록에 없으면 기본 창이다.
    /// 기본 창은 활성 계정을 쓴다.
    func test_primaryWindowMarksTheActiveAccount() {
        let uuid = FocusMark.focusedUUID(
            frontPid: 100, frontExecutable: claude,
            instances: ["NAVER_TEAM_52": 900],
            orgs: orgs, activeUUID: "t40")
        XCTAssertEqual(uuid, "t40")
    }

    /// 다른 앱이 앞이면 아무 계정도 아니다. 밑줄은 "지금 이 창" 이라는
    /// 말이라 남겨두면 거짓말이 된다.
    func test_otherAppInFrontMarksNothing() {
        let uuid = FocusMark.focusedUUID(
            frontPid: 500, frontExecutable: "/Applications/Safari.app/Contents/MacOS/Safari",
            instances: ["NAVER_TEAM_52": 900],
            orgs: orgs, activeUUID: "t40")
        XCTAssertNil(uuid)
    }

    func test_unknownFrontAppMarksNothing() {
        XCTAssertNil(FocusMark.focusedUUID(
            frontPid: nil, frontExecutable: nil,
            instances: [:], orgs: orgs, activeUUID: "t40"))
    }

    /// 앞 인스턴스의 계정이 목록에 없으면 표시할 곳이 없다.
    func test_instanceWithoutKnownOrgMarksNothing() {
        XCTAssertNil(FocusMark.focusedUUID(
            frontPid: 900, frontExecutable: claude,
            instances: ["GONE_TEAM": 900],
            orgs: orgs, activeUUID: "t40"))
    }

    func test_primaryWindowWithoutActiveAccountMarksNothing() {
        XCTAssertNil(FocusMark.focusedUUID(
            frontPid: 100, frontExecutable: claude,
            instances: [:], orgs: orgs, activeUUID: nil))
    }

    /// 인스턴스 디렉토리 이름은 slug 라 공백이 빠진다. 계정 이름과
    /// slug 규칙으로 맞춰 본다.
    func test_slugMatchingFollowsAltInstanceRule() {
        let spaced = [org("sp", "NAVER TEAM 40")]
        let uuid = FocusMark.focusedUUID(
            frontPid: 900, frontExecutable: claude,
            instances: ["NAVERTEAM40": 900],
            orgs: spaced, activeUUID: nil)
        XCTAssertEqual(uuid, "sp")
    }
}
