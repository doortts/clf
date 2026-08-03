import Foundation

public typealias AccountID = String
public typealias ModelID   = String     // 요청 body 의 `model` 값을 그대로 쓴다
public typealias SessionID = String     // X-Claude-Session-Id 헤더

public enum Plan: String, Codable, Sendable {
    case team, enterprise
}

/// 자격증명 종류. docs/design/07-oauth-credentials.md 8절
public enum CredentialKind: String, Codable, Sendable {
    /// `claude setup-token`. 문자열 하나. 1년, 갱신 없음, 추론 전용 스코프
    case longLived
    /// `claude auth login` 캡처. JSON 블록 전체. 갱신 가능, 전체 스코프
    case oauth
}

/// 사용자가 등록한 조직 하나. 토큰은 여기 없다. Keychain 에만 있다.
public struct Account: Codable, Identifiable, Sendable, Hashable {
    public let id: AccountID            // 사용자 지정. 우선순위 체인의 식별자
    public var plan: Plan
    public var baseURL: URL?            // nil 이면 https://api.anthropic.com
    public var note: String?

    /// false 면 자동 전환 후보에서 뺀다. 계정과 토큰은 그대로 남는다.
    /// docs/design/02-domain-model.md 3-3절
    public var autoSwitch: Bool

    public var credentialKind: CredentialKind

    /// 자격증명 등록 시각. longLived 는 1년짜리라 만료를 미리 알려야 한다.
    public var tokenCreatedAt: Date

    /// 접근 토큰의 SHA-256 앞 8바이트. 같은 토큰을 두 번 등록하는 실수를 막는다.
    /// 신원 확인용이 아니다. docs/design/05-account-registration.md 6절
    public var tokenFingerprint: String

    public init(
        id: AccountID,
        plan: Plan,
        baseURL: URL? = nil,
        note: String? = nil,
        autoSwitch: Bool = true,
        credentialKind: CredentialKind,
        tokenCreatedAt: Date,
        tokenFingerprint: String
    ) {
        self.id = id
        self.plan = plan
        self.baseURL = baseURL
        self.note = note
        self.autoSwitch = autoSwitch
        self.credentialKind = credentialKind
        self.tokenCreatedAt = tokenCreatedAt
        self.tokenFingerprint = tokenFingerprint
    }
}
