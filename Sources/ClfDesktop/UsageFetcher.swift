import Foundation
import SQLite3

/// 네트워크 경계. 테스트가 가짜로 갈아끼운다.
public protocol UsageFetching: Sendable {
    /// 추론 요청이 아니다. 읽기 전용이라 토큰을 소모하지 않는다.
    func usage(token: String) async throws -> UsageReport
    /// 계정 이름은 토큰 캐시에 없다. claude.ai 세션으로만 얻는다.
    func orgNames(sessionKey: String) async throws -> [String: String]
    /// 토큰 캐시에 없는 계정을 세션으로 읽는다.
    ///
    /// 앱은 그 계정을 실제로 쓸 때까지 OAuth 토큰을 만들지 않고, Enterprise
    /// 계정은 창을 띄워도 만들지 않는다. 그런 계정도 이 경로로는 읽힌다.
    func usage(org uuid: String, sessionKey: String) async throws -> UsageReport
}

extension UsageFetching {
    /// 세션 경로를 안 쓰는 가짜 구현이 그대로 컴파일되게 둔다.
    public func usage(org uuid: String, sessionKey: String) async throws -> UsageReport {
        throw UsageFetchError(description: "세션으로 읽는 경로가 없다")
    }
}

public struct UsageFetchError: Error, CustomStringConvertible {
    public let description: String
    /// 429. 실패와 다르다. 서버가 그만 물어보라고 한 것이다.
    public let throttled: Bool
    /// 요청이 서버에 닿지도 못했다. 429 와도 다르다. 서버는 아무 말도 안 했고
    /// 우리 쪽 회선이 끊긴 것이라, 회선이 돌아오면 곧바로 다시 읽어야 한다.
    public let offline: Bool

    public init(description: String, throttled: Bool = false, offline: Bool = false) {
        self.description = description
        self.throttled = throttled
        self.offline = offline
    }

    /// URLSession 이 준 전송 오류를 이 자리의 말로 바꾼다.
    ///
    /// 끊김, 시간 초과, DNS 실패를 한 갈래로 묶는다. 셋 다 회선이 돌아오면
    /// 풀리는 것이라 앱이 할 일이 같다. 원문(`Error Domain=NSURLErrorDomain
    /// Code=-1009 ...`)을 그대로 카드에 흘리면 폭에 잘려 읽히지도 않는다.
    public static let noNetwork = UsageFetchError(
        description: "네트워크에 연결하지 못했다. 연결되면 다시 읽는다", offline: true)
}

public struct LiveUsageFetcher: UsageFetching {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let orgsURL = URL(string: "https://claude.ai/api/organizations")!
    /// OAuth 토큰을 Bearer 로 받으려면 이 플래그가 있어야 한다.
    public static let oauthBeta = "oauth-2025-04-20"

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) { self.timeout = timeout }

    public func usage(token: String) async throws -> UsageReport {
        var request = URLRequest(url: Self.usageURL, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(Self.oauthBeta, forHTTPHeaderField: "anthropic-beta")
        return try await send(request)
    }

    /// 계정별 사용량을 claude.ai 세션으로 읽는다. 응답 모양은 OAuth 쪽과 같다.
    public func usage(org uuid: String, sessionKey: String) async throws -> UsageReport {
        guard let url = Self.orgUsageURL(uuid) else {
            throw UsageFetchError(description: "계정 uuid 로 주소를 못 만든다")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "cookie")
        request.setValue("Mozilla/5.0 (Macintosh) Claude/1.0", forHTTPHeaderField: "user-agent")
        return try await send(request)
    }

    /// uuid 가 경로 한 조각이 된다. 서버가 준 값이지만 그대로 붙이지 않는다.
    static func orgUsageURL(_ uuid: String) -> URL? {
        guard let escaped = uuid.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              !escaped.isEmpty else { return nil }
        return URL(string: "https://claude.ai/api/organizations/\(escaped)/usage")
    }

    private func send(_ request: URLRequest) async throws -> UsageReport {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is URLError {
            throw UsageFetchError.noNetwork
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            break
        case 401, 403:
            // 우리가 갱신하지 않고 사용자에게 길을 알려준다
            throw UsageFetchError(description: "토큰 만료. 앱에서 이 계정을 한 번 열면 갱신된다")
        case 429:
            // 짧은 시간에 여러 번 부르면 이게 온다. 더 두드리면 창이 안 열린다
            throw UsageFetchError(description: "요청이 너무 잦다. 잠시 뒤 다시 읽는다",
                                  throttled: true)
        default:
            throw UsageFetchError(description: "Usage API HTTP \(status)")
        }
        return parseReport(data)
    }

    public func orgNames(sessionKey: String) async throws -> [String: String] {
        var request = URLRequest(url: Self.orgsURL, timeoutInterval: timeout)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "cookie")
        request.setValue("Mozilla/5.0 (Macintosh) Claude/1.0", forHTTPHeaderField: "user-agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is URLError {
            throw UsageFetchError.noNetwork
        }
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
