import Foundation
import ClflCore

/// Keychain 에 들어가는 값. 종류에 따라 모양이 다르다.
/// docs/design/07-oauth-credentials.md 8절
public enum StoredCredential: Sendable {
    /// setup-token. 문자열 하나.
    case longLived(token: String)
    /// auth login 캡처. `{"claudeAiOauth": {...}}` 블록 전체.
    case oauth(json: Data)
}

/// auth login 자격증명의 파싱된 모양.
public struct OAuthCredential: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scopes: [String]
    public var subscriptionType: String?

    public var canReadUsageAPI: Bool { scopes.contains("user:profile") }

    public init(
        accessToken: String, refreshToken: String, expiresAt: Date,
        scopes: [String], subscriptionType: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
    }
}

public protocol CredentialStoring: Sendable {
    func credential(for id: AccountID) throws -> StoredCredential
    func store(_ credential: StoredCredential, for id: AccountID) throws
    func remove(_ id: AccountID) throws
    /// 값을 읽지 않고 존재만 확인한다. 점검 화면이 Keychain 잠금 해제를 유발하지
    /// 않게 하려고 따로 둔다.
    func hasCredential(for id: AccountID) -> Bool
}

/// `security` CLI 로 접근한다. Security framework 를 쓰면 개발 빌드마다 코드서명이
/// 바뀌어 프롬프트가 반복된다. docs/design/07-oauth-credentials.md 3절
public struct KeychainCredentialStore: CredentialStoring {
    public static let service = "me.clfl.credentials"

    public init() {}

    public func credential(for id: AccountID) throws -> StoredCredential {
        _ = id
        fatalError("TODO")
    }
    public func store(_ credential: StoredCredential, for id: AccountID) throws {
        _ = (credential, id)
        fatalError("TODO")
    }
    public func remove(_ id: AccountID) throws {
        _ = id
        fatalError("TODO")
    }
    public func hasCredential(for id: AccountID) -> Bool {
        _ = id
        fatalError("TODO")
    }
}
