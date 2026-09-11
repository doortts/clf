import Foundation

/// Codex Usage API 응답 하나. 플랜과 창들.
///
/// ```
/// GET https://chatgpt.com/backend-api/wham/usage
/// Authorization: Bearer <access_token>
/// ChatGPT-Account-Id: <account_id>
/// ```
/// Codex CLI 의 `/status` 가 부르는 곳이다. 추론 요청이 아니라 사용량을
/// 소모하지 않는다. docs/design/18-codex-usage.md 1-2절
public struct CodexReport: Sendable, Equatable {
    public let plan: String?
    public let limits: [LimitKind: UsageLimit]

    public init(plan: String?, limits: [LimitKind: UsageLimit]) {
        self.plan = plan
        self.limits = limits
    }
}

/// 응답을 읽는다. 순수 함수라 테스트가 잠근다.
///
/// 창은 **자리(primary/secondary)가 아니라 길이로** 읽는다. `plus` 의 primary
/// 는 5시간이고 `prolite` 의 primary 는 주간이다. 자리로 읽으면 `prolite`
/// 의 주간이 5시간 줄에 앉는다. docs/design/18-codex-usage.md 1-3절
///
/// ```json
/// {"plan_type": "plus",
///  "rate_limit": {"primary_window":   {"used_percent": 49, "limit_window_seconds": 18000,  "reset_at": 1788462824},
///                 "secondary_window": {"used_percent": 93, "limit_window_seconds": 604800, "reset_at": 1788840284}}}
/// ```
public func parseCodexUsage(_ data: Data) throws -> CodexReport {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw UsageParseError(description: "Codex Usage 응답이 JSON 객체가 아니다")
    }
    var limits: [LimitKind: UsageLimit] = [:]
    let rate = root["rate_limit"] as? [String: Any] ?? [:]
    for key in ["primary_window", "secondary_window"] {
        guard let window = rate[key] as? [String: Any],
              let seconds = number(window["limit_window_seconds"]),
              let used = number(window["used_percent"]) else { continue }
        let kind: LimitKind = seconds < 86_400 ? .session : .weeklyAll
        // 사용률 0 인 창의 reset_at 은 지금 + 창 길이다. 타이머가 안 걸린
        // 창이라 Claude 와 같이 "창 안 열림" 으로 둔다. 4-1절
        let resets = used > 0 ? number(window["reset_at"]).map {
            Date(timeIntervalSince1970: $0)
        } : nil
        // 같은 길이의 창이 둘이면 앞자리를 둔다. 관측된 적 없는 모양이다
        if limits[kind] == nil {
            limits[kind] = UsageLimit(percentUsed: Int(used.rounded()), resetsAt: resets,
                                      severity: "")
        }
    }
    return CodexReport(plan: root["plan_type"] as? String, limits: limits)
}

/// `used_percent` 는 `49.0` 으로도 `49` 로도 온다.
private func number(_ value: Any?) -> Double? {
    switch value {
    case let d as Double: return d
    case let i as Int:    return Double(i)
    default:              return nil
    }
}

/// 네트워크 경계. `UsageFetching` 과 따로 둔다. 저쪽에 얹으면 가짜 구현
/// 전부가 이 메서드를 알아야 한다.
public protocol CodexUsageFetching: Sendable {
    func usage(token: String, accountID: String) async throws -> CodexReport
}

public struct LiveCodexUsageFetcher: CodexUsageFetching {
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) { self.timeout = timeout }

    public func usage(token: String, accountID: String) async throws -> CodexReport {
        var request = URLRequest(url: Self.usageURL, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is URLError {
            throw UsageFetchError.noNetwork
        }
        // 오류 갈래는 Claude 쪽과 같다. 같아야 ReadGate 와 RefreshPacer 가
        // 두 공급자를 한 자리에서 다룬다
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            return try parseCodexUsage(data)
        case 401, 403:
            throw UsageFetchError(description: "토큰 만료. Codex 에서 한 번 쓰면 갱신된다")
        case 429:
            throw UsageFetchError(description: "요청이 너무 잦다. 잠시 뒤 다시 읽는다",
                                  throttled: true)
        case let status:
            throw UsageFetchError(description: "Codex Usage API HTTP \(status)")
        }
    }
}
