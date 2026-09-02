import Foundation

/// 앱이 `config.json` 의 `oauth:tokenCacheV2` 에 캐시해 둔 계정별 토큰 하나.
///
/// 우리는 읽기만 한다. 갱신은 앱이 한다. 만료되면 사용자가 앱에서 그 계정을
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

/// 복호화된 토큰 캐시 JSON 을 계정 uuid 로 색인한다.
///
/// 캐시 키가 이렇게 생겼다.
/// ```
/// 9d1c250a-...:746e81ae-...:https://api.anthropic.com:user:inference user:profile ...
/// ^ clientId   ^ orgId       ^ host                    ^ scopes
/// ```
/// 콜론이 host 와 scopes 안에도 있으므로 **앞에서 두 번째 조각**만 떼야 한다.
/// 뒤에서 세거나 전부 쪼개면 어긋난다.
///
/// 앱이 어느 버전부터 clientId 자리에 `계정|clientId` 를 넣고 키 맨 앞에
/// `acct` 표시를 하나 더 붙인다.
/// ```
/// acct:914e4f12-...|9d1c250a-...:746e81ae-...:https://api.anthropic.com:user:profile
/// ^표시  ^ 계정       ^ clientId    ^ orgId
/// ```
/// 그 표시만 떼면 조각 자리가 예전 키와 같아진다. 안 떼면 `계정|clientId` 를
/// orgId 로 읽어서 팝오버에 계정 이름 대신 uuid 앞 8글자가 뜨고, clientId 가
/// 두 개면 같은 계정이 두 줄로 늘어난다.
public func parseTokenCache(_ data: Data) throws -> [String: DesktopToken] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SafeStorageError(description: "토큰 캐시가 JSON 객체가 아니다")
    }

    var out: [String: DesktopToken] = [:]
    for (cacheKey, value) in root {
        var parts = cacheKey.split(separator: ":", omittingEmptySubsequences: false)
        if parts.first == "acct", parts.count >= 2, parts[1].contains("|") {
            parts.removeFirst()
        }
        guard parts.count >= 2, let record = value as? [String: Any],
              let token = record["token"] as? String else { continue }

        let org = String(parts[1])
        guard !org.isEmpty else { continue }

        // expiresAt 은 밀리초 epoch 다. Claude 가 그렇게 쓴다
        let expires = (record["expiresAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        // 한 계정에 스코프가 다른 키가 여러 개 있다. 그대로 덮어쓰면 사전
        // 순회 순서에 따라 user:profile 없는 토큰이 남아 사용량을 못 읽는다
        let parsed = DesktopToken(
            token: token,
            subscriptionType: record["subscriptionType"] as? String,
            rateLimitTier: record["rateLimitTier"] as? String,
            expiresAt: expires,
            canReadUsage: cacheKey.contains("user:profile"))
        out[org] = out[org].map { DesktopReader.fresher($0, parsed) } ?? parsed
    }
    return out
}
