import Foundation
import ClfCore

/// Keychain 에 들어가는 값. 종류에 따라 모양이 다르다.
/// docs/design/07-oauth-credentials.md 8절
public enum StoredCredential: Sendable, Equatable {
    /// setup-token. 문자열 하나.
    case longLived(token: String)
    /// auth login 캡처. `{"claudeAiOauth": {...}}` 블록 전체.
    case oauth(json: Data)

    /// 저장 형식. 앞의 두 글자가 종류를 말한다.
    ///
    /// 내용으로 추측하지 않는다. oauth JSON 이 언젠가 다른 모양이 되거나 토큰 접두사가
    /// 바뀌어도 이 태그는 그대로다. 읽는 쪽이 Account.credentialKind 를 들고 다니지
    /// 않아도 되게 하려는 것이기도 하다.
    var wireFormat: String {
        switch self {
        case .longLived(let token): return "L:\(token)"
        case .oauth(let json):      return "O:" + String(decoding: json, as: UTF8.self)
        }
    }

    init?(wireFormat: String) {
        let body = String(wireFormat.dropFirst(2))
        switch wireFormat.prefix(2) {
        case "L:": self = .longLived(token: body)
        case "O:": self = .oauth(json: Data(body.utf8))
        default:   return nil
        }
    }
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

    /// `{"claudeAiOauth": {...}}` 블록을 읽는다. 바깥 껍질 없이 안쪽만 온 것도 받는다.
    ///
    /// expiresAt 은 밀리초 epoch 다. Claude CLI 가 그렇게 쓴다.
    public init?(claudeAiOauthJSON data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let block = root["claudeAiOauth"] as? [String: Any] ?? root

        guard let access = block["accessToken"] as? String, !access.isEmpty,
              let refresh = block["refreshToken"] as? String,
              let expiresMillis = block["expiresAt"] as? Double
        else { return nil }

        // scopes 는 배열이거나 공백으로 이어붙인 문자열이다.
        let scopes: [String]
        if let list = block["scopes"] as? [String] {
            scopes = list
        } else if let joined = block["scopes"] as? String {
            scopes = joined.split(separator: " ").map(String.init)
        } else {
            scopes = []
        }

        self.init(accessToken: access, refreshToken: refresh,
                  expiresAt: Date(timeIntervalSince1970: expiresMillis / 1000),
                  scopes: scopes,
                  subscriptionType: block["subscriptionType"] as? String)
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
    public static let service = "me.clf.credentials"

    /// 이름을 clfl 에서 clf 로 바꾸기 전에 넣은 항목이 쓰던 서비스 이름.
    ///
    /// **읽을 때만 본다.** Keychain 항목은 우리가 옮길 수 없다. 값을 꺼내
    /// 다시 넣어야 하는데 그러려면 비밀값이 한 번 더 argv 를 타고, 사용자는
    /// 아무것도 안 했는데 자격증명이 옮겨 다니게 된다. 대신 옛 이름으로도
    /// 찾아보고, 다음에 그 계정을 다시 넣을 때 새 이름으로 자리 잡게 둔다.
    public static let legacyService = "me.clfl.credentials"

    private let service: String
    private let legacy: String?

    public init(service: String = KeychainCredentialStore.service,
                legacy: String? = KeychainCredentialStore.legacyService) {
        self.service = service
        self.legacy = legacy
    }

    public func credential(for id: AccountID) throws -> StoredCredential {
        guard let raw = try find(id) else {
            throw StoreError.credentialMissing(id)
        }
        guard let credential = StoredCredential(wireFormat: raw) else {
            throw StoreError.keychainFailed(reason: """
            \(id) 의 Keychain 항목을 읽을 수 없다. 등록할 때 값이 오염됐을 수 있다.
            지우고 다시 넣는다:
              clfctl accounts remove \(id)
              clfctl accounts add \(id) --plan team
            """)
        }
        return credential
    }

    /// -U 는 같은 (service, account) 항목을 덮어쓴다. 없으면 만든다.
    ///
    /// 비밀값이 argv 로 간다. macOS 는 다른 사용자의 argv 를 못 읽고, 같은 사용자는
    /// 어차피 이 Keychain 항목에 접근할 수 있으므로 노출 범위가 늘지 않는다.
    /// security CLI 에 stdin 으로 넣는 방법이 없어 남는 유일한 경로다.
    public func store(_ credential: StoredCredential, for id: AccountID) throws {
        let result = try SecurityCLI.run([
            "add-generic-password", "-U",
            "-s", service, "-a", id,
            "-D", "clf credential",
            "-w", credential.wireFormat,
        ])
        guard result.status == 0 else {
            throw StoreError.keychainFailed(reason: result.stderr)
        }
    }

    /// 없는 항목을 지우는 것은 성공이다. 호출부가 존재를 먼저 확인하지 않아도 된다.
    ///
    /// 옛 이름 항목도 같이 지운다. 지운 줄 알았는데 남아 있으면 다음 읽기가
    /// 그것을 찾아내 되살아난 것처럼 보인다.
    public func remove(_ id: AccountID) throws {
        for name in [service] + (legacy.map { [$0] } ?? []) {
            let result = try SecurityCLI.run(["delete-generic-password", "-s", name, "-a", id])
            guard result.status == 0 || result.status == SecurityCLI.itemNotFound else {
                throw StoreError.keychainFailed(reason: result.stderr)
            }
        }
    }

    /// -w 를 빼면 속성만 읽는다. 비밀값 접근이 아니라 잠금 해제 프롬프트가 뜨지 않는다.
    public func hasCredential(for id: AccountID) -> Bool {
        for name in [service] + (legacy.map { [$0] } ?? []) {
            let result = try? SecurityCLI.run(["find-generic-password", "-s", name, "-a", id])
            if result?.status == 0 { return true }
        }
        return false
    }

    /// 새 이름으로 먼저 찾고 없으면 옛 이름으로 찾는다.
    private func find(_ id: AccountID) throws -> String? {
        if let raw = try SecurityCLI.findPassword(service: service, account: id) { return raw }
        guard let legacy else { return nil }
        return try SecurityCLI.findPassword(service: legacy, account: id)
    }
}

/// 테스트와 미리보기용. Keychain 을 건드리지 않는다.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AccountID: StoredCredential] = [:]

    public init(_ items: [AccountID: StoredCredential] = [:]) { self.items = items }

    public func credential(for id: AccountID) throws -> StoredCredential {
        lock.lock(); defer { lock.unlock() }
        guard let item = items[id] else { throw StoreError.credentialMissing(id) }
        return item
    }
    public func store(_ credential: StoredCredential, for id: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        items[id] = credential
    }
    public func remove(_ id: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        items[id] = nil
    }
    public func hasCredential(for id: AccountID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return items[id] != nil
    }
}

// MARK: 지문

import CryptoKit

/// 접근 토큰의 SHA-256 앞 8바이트. 같은 토큰을 두 번 등록하는 실수를 막는다.
/// 신원 확인용이 아니다. docs/design/05-account-registration.md 6절
public func tokenFingerprint(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).prefix(8)
        .map { String(format: "%02x", $0) }.joined()
}
