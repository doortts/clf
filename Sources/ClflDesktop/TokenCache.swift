import Foundation

/// 앱이 `config.json` 의 `oauth:tokenCacheV2` 에 캐시해 둔 조직별 토큰 하나.
///
/// 우리는 읽기만 한다. 갱신은 앱이 한다. 만료되면 사용자가 앱에서 그 조직을
/// 한 번 열면 되므로 우리가 갱신 경로를 들 이유가 없다.
public struct DesktopToken: Sendable, Equatable {
    public let token: String
    public let subscriptionType: String?
    public let rateLimitTier: String?
    public let expiresAt: Date?
    /// Usage API 는 `user:profile` 을 요구한다. 없는 토큰은 부를 필요가 없다.
    public let canReadUsage: Bool

    public init(token: String, subscriptionType: String?, rateLimitTier: String?,
                expiresAt: Date?, canReadUsage: Bool) {
        self.token = token
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.expiresAt = expiresAt
        self.canReadUsage = canReadUsage
    }
}

/// 복호화된 토큰 캐시 JSON 을 조직 uuid 로 색인한다.
///
/// 캐시 키가 이렇게 생겼다.
/// ```
/// 9d1c250a-...:746e81ae-...:https://api.anthropic.com:user:inference user:profile ...
/// ^ clientId   ^ orgId       ^ host                    ^ scopes
/// ```
/// 콜론이 host 와 scopes 안에도 있으므로 **앞에서 두 번째 조각**만 떼야 한다.
/// 뒤에서 세거나 전부 쪼개면 어긋난다.
public func parseTokenCache(_ data: Data) throws -> [String: DesktopToken] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SafeStorageError(description: "토큰 캐시가 JSON 객체가 아니다")
    }

    var out: [String: DesktopToken] = [:]
    for (cacheKey, value) in root {
        let parts = cacheKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, let record = value as? [String: Any],
              let token = record["token"] as? String else { continue }

        let org = String(parts[1])
        guard !org.isEmpty else { continue }

        // expiresAt 은 밀리초 epoch 다. Claude 가 그렇게 쓴다
        let expires = (record["expiresAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        out[org] = DesktopToken(
            token: token,
            subscriptionType: record["subscriptionType"] as? String,
            rateLimitTier: record["rateLimitTier"] as? String,
            expiresAt: expires,
            canReadUsage: cacheKey.contains("user:profile"))
    }
    return out
}
