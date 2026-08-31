import Foundation

/// 앱이 마지막으로 어느 계정에 요청을 보냈나.
///
/// 앱은 Sentry 에 붙일 빵조각을 `sentry/scope_v3.json` 에 계속 적는다. 자기가
/// 부른 URL 이 시각과 함께 순서대로 들어 있고, 계정별 엔드포인트는 경로에
/// 계정 uuid 를 담는다.
/// ```
/// https://claude.ai/api/organizations/<uuid>/skills/list-skills
/// https://claude.ai/api/bootstrap/<uuid>/current_user_access
/// ```
/// 앱이 자기 파일에 직접 적는 평문이라 `lastActiveOrg` 쿠키와 달리 서버
/// 응답을 안 기다린다. 계정을 바꾸면 곧바로 새 계정으로 요청이 나가므로
/// **마지막 것이 지금 쓰는 계정이다.** docs/design/09-desktop-org-switch.md 2절
///
/// **읽기만 한다.** 앱이 쓰는 파일을 고치지 않는다.
enum OrgTrace {
    static let relativePath = "sentry/scope_v3.json"

    /// 계정 uuid 를 경로에 담는 URL 두 갈래. 실측으로 이 둘뿐이었다.
    static let orgPrefixes = ["https://claude.ai/api/organizations/",
                              "https://claude.ai/api/bootstrap/"]

    static func lastOrg(in directory: URL) -> String? {
        guard let data = FileManager.default
                .contents(atPath: directory.appendingPathComponent(relativePath).path)
        else { return nil }
        return lastOrg(scope: data)
    }

    /// 빵조각은 오래된 것부터 쌓인다. 뒤에서부터 찾아 처음 걸리는 것이 답이다.
    ///
    /// 100개짜리 고리라 그 안에 계정 URL 이 하나도 없을 수 있다. 그때는 nil 을
    /// 주고 부르는 쪽이 쿠키로 되돌아간다.
    static func lastOrg(scope data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scope = root["scope"] as? [String: Any],
              let crumbs = scope["breadcrumbs"] as? [[String: Any]] else { return nil }
        for crumb in crumbs.reversed() {
            guard let url = (crumb["data"] as? [String: Any])?["url"] as? String,
                  let org = org(inURL: url) else { continue }
            return org
        }
        return nil
    }

    /// 위 두 갈래만 본다. 사람이나 대화의 uuid 를 계정으로 잘못 읽으면 활성
    /// 표시가 엉뚱한 줄에 붙거나 통째로 사라진다.
    static func org(inURL url: String) -> String? {
        for prefix in orgPrefixes where url.hasPrefix(prefix) {
            let uuid = String(url.dropFirst(prefix.count).prefix { $0 != "/" && $0 != "?" })
            if UUID(uuidString: uuid) != nil { return uuid }
        }
        return nil
    }
}
