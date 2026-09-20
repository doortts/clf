import Foundation

/// Antigravity 앱이 띄운 로컬 서버에 사용량을 물어 `OrgUsage` 하나를 만든다.
///
/// **읽기만 한다.** Claude, Codex 와 같은 자세다. 다만 이쪽은 토큰이 디스크에
/// 없어서 **앱이 떠 있는 동안만 읽힌다.** docs/design/19-antigravity-usage.md
public struct AntigravityReader: Sendable {
    /// 계정 uuid 자리. Antigravity 는 기계에 프로필이 하나라 상수면 된다.
    ///
    /// 앱이 꺼져 있어도, 한 번도 안 켰어도 같은 값이라 **숨김과 순서 설정이
    /// 안 풀린다.** 앱을 켤 때마다 바뀌는 값을 쓰면 그때마다 카드가 새것처럼
    /// 나타난다.
    public static let accountID = "antigravity"
    public static let name = "Antigravity"
    /// 앱이 꺼져 있을 때 카드에 적는 말. 이유와 할 일이 한 줄에 있어야 한다.
    public static let offMessage = "Antigravity 가 꺼져 있다. 켜면 다시 읽는다"

    public static let defaultAppPaths = [
        URL(fileURLWithPath: "/Applications/Antigravity.app"),
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Antigravity.app"),
    ]

    private let appPaths: [URL]
    private let probe: any AntigravityProbing
    private let session: any AntigravityUsageFetching

    public init(appPaths: [URL] = AntigravityReader.defaultAppPaths,
                probe: any AntigravityProbing = LiveAntigravityProbe(),
                session: any AntigravityUsageFetching = LiveAntigravityFetcher()) {
        self.appPaths = appPaths
        self.probe = probe
        self.session = session
    }

    public var isInstalled: Bool {
        appPaths.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 던지지 않는다. 앱이 없으면 빈 결과다. Claude 만 쓰는 사람에게
    /// Antigravity 가 없는 것은 오류가 아니다.
    public func read() async -> ProviderResult {
        guard isInstalled else { return .empty }
        guard let endpoint = probe.endpoint() else {
            // 값을 못 읽은 것과 앱이 꺼진 것은 다르다. 사용자가 할 일도 다르다.
            // 회선 문제가 아니므로 offline 을 켜지 않는다. 켜면 갱신 주기가
            // 느려지는데, 앱이 켜지는 순간은 우리가 빨리 알아채야 한다
            return ProviderResult(orgs: [org(plan: nil, limits: [:], error: Self.offMessage)])
        }

        var last: (any Error)?
        // 큰 포트가 평문 HTTP 다. 틀리면 남은 포트로 넘어간다. 둘뿐이라
        // 이것으로 끝난다. docs/design/19-antigravity-usage.md 3-1절
        for port in endpoint.ports {
            do {
                let report = try await session.report(port: port, token: endpoint.token)
                return ProviderResult(orgs: [org(plan: report.plan, limits: report.limits)])
            } catch {
                last = error
            }
        }
        let fetch = last as? UsageFetchError
        return ProviderResult(orgs: [org(plan: nil, limits: [:],
                                         error: last.map { "\($0)" } ?? "포트를 못 찾았다")],
                              throttled: fetch?.throttled == true,
                              offline: fetch?.offline == true)
    }

    private func org(plan: String?, limits: [LimitKind: UsageLimit],
                     error: String? = nil) -> OrgUsage {
        // 활성 개념이 없다. 차례는 Preferences 가 공급자로 정한다
        OrgUsage(uuid: Self.accountID, name: Self.name, isActive: false, plan: plan,
                 provider: .antigravity, limits: limits, error: error)
    }
}
