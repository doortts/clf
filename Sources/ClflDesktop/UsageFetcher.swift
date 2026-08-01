import Foundation
import SQLite3

/// 네트워크 경계. 테스트가 가짜로 갈아끼운다.
public protocol UsageFetching: Sendable {
    /// 추론 요청이 아니다. 읽기 전용이라 토큰을 소모하지 않는다.
    func usage(token: String) async throws -> [LimitKind: UsageLimit]
    /// 조직 이름은 토큰 캐시에 없다. claude.ai 세션으로만 얻는다.
    func orgNames(sessionKey: String) async throws -> [String: String]
}

public struct UsageFetchError: Error, CustomStringConvertible {
    public let description: String
}

public struct LiveUsageFetcher: UsageFetching {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let orgsURL = URL(string: "https://claude.ai/api/organizations")!
    /// OAuth 토큰을 Bearer 로 받으려면 이 플래그가 있어야 한다.
    public static let oauthBeta = "oauth-2025-04-20"

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) { self.timeout = timeout }

    public func usage(token: String) async throws -> [LimitKind: UsageLimit] {
        var request = URLRequest(url: Self.usageURL, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(Self.oauthBeta, forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // 401 은 토큰 만료다. 우리가 갱신하지 않고 사용자에게 길을 알려준다
            throw UsageFetchError(description: status == 401
                ? "토큰 만료. 앱에서 이 조직을 한 번 열면 갱신된다"
                : "Usage API HTTP \(status)")
        }
        return try parseUsage(data)
    }

    public func orgNames(sessionKey: String) async throws -> [String: String] {
        var request = URLRequest(url: Self.orgsURL, timeoutInterval: timeout)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "cookie")
        request.setValue("Mozilla/5.0 (Macintosh) Claude/1.0", forHTTPHeaderField: "user-agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [:] }

        let object = try? JSONSerialization.jsonObject(with: data)
        let list = (object as? [[String: Any]])
            ?? ((object as? [String: Any])?["organizations"] as? [[String: Any]])
            ?? []
        return Dictionary(uniqueKeysWithValues: list.compactMap { org -> (String, String)? in
            guard let uuid = org["uuid"] as? String,
                  let name = org["name"] as? String else { return nil }
            return (uuid, name)
        })
    }
}

/// Cookies DB 에서 암호화된 값 하나를 꺼낸다.
///
/// SQLite 를 직접 부른다. 값 하나 읽자고 의존성을 늘릴 이유가 없다.
func readCookieBlob(from url: URL, name: String) throws -> Data? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        throw SafeStorageError(description: "Cookies DB 를 열지 못했다")
    }
    defer { sqlite3_close(db) }

    var statement: OpaquePointer?
    let sql = "select encrypted_value from cookies where host_key = ? and name = ?"
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw SafeStorageError(description: "쿠키 질의를 준비하지 못했다")
    }
    defer { sqlite3_finalize(statement) }

    // SQLITE_TRANSIENT. 바인딩한 문자열을 SQLite 가 복사하게 한다
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, ".claude.ai", -1, transient)
    sqlite3_bind_text(statement, 2, name, -1, transient)

    guard sqlite3_step(statement) == SQLITE_ROW,
          let bytes = sqlite3_column_blob(statement, 0) else { return nil }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
}
