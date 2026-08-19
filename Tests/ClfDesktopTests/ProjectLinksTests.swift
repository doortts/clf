import XCTest
@testable import ClfDesktop

/// 기계가 부르는 주소와 사람이 여는 주소.
///
/// 조립 실수는 눌러 보기 전에는 안 보이고 눌러 보는 사람은 대개 사용자다.
/// 결과 문자열을 그대로 잠근다. docs/design/17-repo-split.html 3절
final class ProjectLinksTests: XCTestCase {

    /// 앱이 부르는 것은 이 호출 하나다. 익명으로 읽힌다.
    func test_machineLinksGoToThePublicRepo() {
        XCTAssertEqual(ProjectLinks.latestRelease.absoluteString,
                       "https://api.github.com/repos/doortts/clf/releases/latest")
    }

    /// 사람이 여는 것은 전부 사내 GHE 다.
    func test_humanLinksGoToTheInternalRepo() {
        XCTAssertEqual(ProjectLinks.newIssue.absoluteString,
                       "https://oss.navercorp.com/sw-chae/clf/issues/new")
        XCTAssertEqual(ProjectLinks.releases.absoluteString,
                       "https://oss.navercorp.com/sw-chae/clf/releases")
        XCTAssertEqual(ProjectLinks.releasePage(tag: "v0.5.0").absoluteString,
                       "https://oss.navercorp.com/sw-chae/clf/releases/tag/v0.5.0")
    }

    /// 두 쪽이 섞이면 안 된다. 기계 링크에 사내 호스트가 들어가면 사내망 밖에서
    /// 업데이트가 멈추고, 사람 링크가 공개 저장소로 가면 이슈가 갈라진다.
    func test_theTwoHostsNeverCross() {
        XCTAssertTrue(ProjectLinks.latestRelease.absoluteString.contains("api.github.com"))
        for url in [ProjectLinks.home, ProjectLinks.newIssue, ProjectLinks.releases,
                    ProjectLinks.releasePage(tag: "v1.0.0")] {
            XCTAssertEqual(url.host(), "oss.navercorp.com", "\(url) 는 사람용이다")
        }
    }

    /// 태그가 비는 것은 릴리즈를 못 읽은 상태다. `releases/tag/` 로 보내면
    /// GitHub 이 404 를 주므로 목록으로 보낸다.
    func test_emptyTagFallsBackToTheList() {
        XCTAssertEqual(ProjectLinks.releasePage(tag: ""), ProjectLinks.releases)
        XCTAssertEqual(ProjectLinks.releasePage(tag: "  \n"), ProjectLinks.releases)
    }
}
