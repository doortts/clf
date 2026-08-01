import Foundation

/// ~/.claude/settings.json 의 env 블록만 관리한다.
/// docs/design/01-architecture.md 4절
///
/// 규칙
///   - read-modify-write. 모르는 키는 전부 보존한다. 사용자의 hooks, statusLine,
///     permissions, model 을 절대 잃지 않는다
///   - 최초 쓰기 전에 settings.json.clfl.bak 로 백업
///   - 우리가 만지는 키는 env.ANTHROPIC_BASE_URL 과 env.ENABLE_TOOL_SEARCH 둘뿐
///   - 이미 다른 값이 있으면 거부. force 로만 덮어쓴다
///   - CLAUDE_CONFIG_DIR 이 있으면 그 경로를 쓴다
public protocol ClaudeSettingsManaging: Sendable {
    func readManagedBaseURL() throws -> URL?
    /// enableToolSearch 는 **항상 true 로 부른다.** 프록시를 거치면 Claude Code 가
    /// MCP 도구 검색을 스스로 끄는데, 우리는 응답을 바이트 그대로 릴레이하므로
    /// 켜도 안전하다. 사용자가 꺼진 것을 눈치채고 설정을 뒤지게 만들면 진 것이다.
    func install(baseURL: URL, enableToolSearch: Bool, force: Bool) throws
    func uninstall() throws
}

public struct ClaudeSettingsFile: ClaudeSettingsManaging {
    public static let baseURLKey = "ANTHROPIC_BASE_URL"
    public static let toolSearchKey = "ENABLE_TOOL_SEARCH"

    private let settingsURL: URL
    private let backupURL: URL
    /// 설치 전 값을 적어둔다. 이걸 남기지 않으면 uninstall 이 사용자가 원래 갖고
    /// 있던 ENABLE_TOOL_SEARCH 를 지워버린다. 우리 파일이므로 사용자 설정을
    /// 표식으로 더럽히지 않는다.
    private let priorStateURL: URL

    public init(configDirectory: URL? = nil, stateDirectory: URL? = nil) throws {
        let config = try configDirectory ?? Self.defaultConfigDirectory()
        self.settingsURL = config.appendingPathComponent("settings.json")
        self.backupURL = config.appendingPathComponent("settings.json.clfl.bak")
        self.priorStateURL = try (stateDirectory ?? appSupportDirectory())
            .appendingPathComponent("claude-settings-prior.json")
    }

    public static func defaultConfigDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    public func readManagedBaseURL() throws -> URL? {
        guard let raw = try readSettings()[Self.envKey] as? [String: Any],
              let value = raw[Self.baseURLKey] as? String
        else { return nil }
        return URL(string: value)
    }

    public func install(baseURL: URL, enableToolSearch: Bool, force: Bool) throws {
        var settings = try readSettings()
        var env = settings[Self.envKey] as? [String: Any] ?? [:]

        let ours = baseURL.absoluteString
        if let existing = env[Self.baseURLKey] as? String, existing != ours, !force {
            throw StoreError.settingsConflict(key: Self.baseURLKey, existing: existing)
        }

        try backupOnce()
        try recordPriorStateOnce(env: env)

        env[Self.baseURLKey] = ours
        env[Self.toolSearchKey] = enableToolSearch ? "true" : "false"
        settings[Self.envKey] = env
        try writeSettings(settings)
    }

    /// 사용자가 앱을 끄면 Claude Code 가 고장 나는 것이 아니라 원래대로 돌아가야 한다.
    public func uninstall() throws {
        var settings = try readSettings()
        guard var env = settings[Self.envKey] as? [String: Any] else { return }

        let prior = readPriorState()
        for key in [Self.baseURLKey, Self.toolSearchKey] {
            if let restored = prior[key] {
                env[key] = restored
            } else {
                env.removeValue(forKey: key)
            }
        }

        // 우리 때문에 생긴 빈 블록을 남기지 않는다. 원래 비어 있었더라도 결과는 같다.
        if env.isEmpty {
            settings.removeValue(forKey: Self.envKey)
        } else {
            settings[Self.envKey] = env
        }
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: priorStateURL)
    }

    // MARK: 내부

    private static let envKey = "env"

    private func readSettings() throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: settingsURL.path),
              !data.isEmpty
        else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { throw StoreError.corruptFile(settingsURL) }
        return dict
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try atomicWrite(data, to: settingsURL)
    }

    private func backupOnce() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              !FileManager.default.fileExists(atPath: backupURL.path)
        else { return }
        try FileManager.default.copyItem(at: settingsURL, to: backupURL)
    }

    /// 처음 설치할 때 한 번만 적는다. 두 번째 install 은 이미 우리 값이 들어간
    /// 상태를 보므로 그걸 원래 값이라고 적으면 안 된다.
    private func recordPriorStateOnce(env: [String: Any]) throws {
        guard !FileManager.default.fileExists(atPath: priorStateURL.path) else { return }
        var prior: [String: String] = [:]
        for key in [Self.baseURLKey, Self.toolSearchKey] {
            if let value = env[key] as? String { prior[key] = value }
        }
        try atomicWrite(try makeEncoder().encode(prior), to: priorStateURL)
    }

    private func readPriorState() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: priorStateURL.path),
              let prior = try? makeDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return prior
    }
}
