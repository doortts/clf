import Foundation

/// Codex 읽기 결과. 계정이 하나라 스냅샷을 따로 만들 것이 없다.
public struct CodexResult: Sendable, Equatable {
    public let orgs: [OrgUsage]
    public let throttled: Bool
    public let offline: Bool

    public init(orgs: [OrgUsage], throttled: Bool = false, offline: Bool = false) {
        self.orgs = orgs
        self.throttled = throttled
        self.offline = offline
    }

    public static let empty = CodexResult(orgs: [])
}

/// `~/.codex/auth.json` 을 읽어 Codex 계정 하나를 `OrgUsage` 로 만든다.
///
/// **읽기만 한다.** Claude 와 같은 자세다. 토큰 갱신은 Codex 가 한다.
/// 파일이 평문 JSON 이라 Keychain 도 복호화도 없다. docs/design/18-codex-usage.md
public struct CodexReader: Sendable {
    public static let defaultHome =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    /// 카드 이름과 막대 코드(`Co`)가 여기서 나온다. 이메일은 쓰지 않는다.
    public static let name = "Codex"

    private let home: URL
    private let session: any CodexUsageFetching

    /// `home` 을 인자로 받는다. 둘째 계정(`CODEX_HOME` 여럿)을 붙일 때
    /// 이 자리에 디렉토리만 더 주면 된다. 6절
    public init(home: URL = CodexReader.defaultHome,
                session: any CodexUsageFetching = LiveCodexUsageFetcher()) {
        self.home = home
        self.session = session
    }

    private var authFile: URL { home.appendingPathComponent("auth.json") }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: authFile.path)
    }

    /// 던지지 않는다. 파일이 없으면 빈 결과다. Claude 만 쓰는 사람에게
    /// Codex 가 없는 것은 오류가 아니다.
    public func read() async -> CodexResult {
        guard let auth = try? readAuth() else { return .empty }
        do {
            let report = try await session.usage(token: auth.token, accountID: auth.accountID)
            return CodexResult(orgs: [org(auth, plan: report.plan, limits: report.limits)])
        } catch {
            let fetch = error as? UsageFetchError
            return CodexResult(orgs: [org(auth, plan: nil, limits: [:], error: "\(error)")],
                               throttled: fetch?.throttled == true,
                               offline: fetch?.offline == true)
        }
    }

    private func org(_ auth: CodexAuth, plan: String?, limits: [LimitKind: UsageLimit],
                     error: String? = nil) -> OrgUsage {
        // 활성 개념이 없다. 그 하나가 곧 활성이지만 isActive 는 Claude 기본 창의
        // 뜻이라 켜지 않는다. 차례는 Preferences 가 공급자로 정한다
        OrgUsage(uuid: auth.accountID, name: Self.name, isActive: false, plan: plan,
                 provider: .codex, limits: limits, error: error)
    }

    struct CodexAuth: Equatable {
        let token: String
        let accountID: String
    }

    /// ```json
    /// {"tokens": {"access_token": "eyJ...", "account_id": "c7bbb1fc-..."}}
    /// ```
    func readAuth() throws -> CodexAuth {
        guard let data = FileManager.default.contents(atPath: authFile.path) else {
            throw UsageFetchError(description: "auth.json 이 없다")
        }
        return try parseCodexAuth(data)
    }
}

func parseCodexAuth(_ data: Data) throws -> CodexReader.CodexAuth {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = root["tokens"] as? [String: Any],
          let token = tokens["access_token"] as? String, !token.isEmpty,
          let account = tokens["account_id"] as? String, !account.isEmpty
    else { throw UsageFetchError(description: "auth.json 에 access_token 이나 account_id 가 없다") }
    return CodexReader.CodexAuth(token: token, accountID: account)
}
