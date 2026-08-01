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
    public init() {}

    public func readManagedBaseURL() throws -> URL? { fatalError("TODO") }
    public func install(baseURL: URL, enableToolSearch: Bool, force: Bool) throws {
        _ = (baseURL, enableToolSearch, force)
        fatalError("TODO")
    }
    public func uninstall() throws { fatalError("TODO") }
}
