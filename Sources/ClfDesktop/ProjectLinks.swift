import Foundation

/// 앱에서 바깥으로 나가는 주소 전부.
///
/// **기계가 부르는 주소는 전부 `github.com` 이고, 사람이 여는 주소는 전부
/// `oss.navercorp.com` 이다.** 앱은 GitHub 자격증명을 하나도 갖고 있지 않아서
/// 익명으로 읽히는 공개 저장소만 부를 수 있고, 이 앱을 쓰는 사람은 전원 사내
/// 계정이 있어서 이슈와 노트를 읽는 자리는 GHE 가 자연스럽다.
/// docs/design/17-repo-split.html
///
/// 주소를 여기 한 곳에만 둔다. 저장소를 옮기는 날 고칠 곳이 이 파일 하나여야
/// 한다. 조립 실수는 눌러 보기 전에는 안 보이고 눌러 보는 사람은 대개
/// 사용자라서, 조립 결과를 테스트가 문자열로 잠근다.
public enum ProjectLinks {

    // MARK: 기계용. 익명으로 읽히는 공개 저장소

    /// 릴리즈 자산이 놓이는 곳. `소유자/저장소` 꼴이다.
    public static let updateRepo = "doortts/clf"

    /// 앱이 부르는 유일한 API. 익명이라 시간당 60회를 IP 로 나눠 쓴다.
    public static var latestRelease: URL {
        URL(string: "https://api.github.com/repos/\(updateRepo)/releases/latest")!
    }

    // MARK: 사람용. 사내 GHE

    /// 소스 원본과 이슈가 사는 곳.
    public static let home = URL(string: "https://oss.navercorp.com/sw-chae/clf")!

    public static var newIssue: URL {
        home.appendingPathComponent("issues").appendingPathComponent("new")
    }

    public static var releases: URL {
        home.appendingPathComponent("releases")
    }

    /// 그 태그의 릴리즈 페이지. 노트 전문과 직접 받을 DMG 가 여기 있다.
    ///
    /// 빈 태그면 목록으로 보낸다. 태그가 비는 것은 릴리즈를 못 읽은 상태라
    /// 그때 `releases/tag/` 로 보내면 GitHub 이 404 를 준다. 목록은 언제나
    /// 열리고 거기서 사람이 찾을 수 있다.
    public static func releasePage(tag: String) -> URL {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return releases }
        return releases.appendingPathComponent("tag").appendingPathComponent(trimmed)
    }
}
