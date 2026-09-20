import Foundation

/// Antigravity 로컬 RPC 응답 하나. 플랜과 창들.
///
/// ```
/// POST http://127.0.0.1:<포트>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary
/// x-codeium-csrf-token: <토큰>
/// ```
/// 앱이 띄우는 `language_server` 가 받는다. 추론 요청이 아니라 사용량을
/// 소모하지 않는다. docs/design/19-antigravity-usage.md 1-2절
public struct AntigravityReport: Sendable, Equatable {
    public let plan: String?
    public let limits: [LimitKind: UsageLimit]

    public init(plan: String?, limits: [LimitKind: UsageLimit]) {
        self.plan = plan
        self.limits = limits
    }
}

/// 사용량 응답에서 Gemini 묶음의 두 창을 읽는다.
///
/// 응답에는 묶음이 둘이고 묶음마다 창이 둘이라 칸이 넷인데 **둘만 쓴다.**
/// 둘째 묶음(`3p-`)은 Antigravity 안에서 Claude 나 GPT 모델을 골라 쓸 때만
/// 닳는 별도 주머니다. Gemini 를 쓰는 사람에게는 영원히 100% 인 두 줄이
/// 자리만 먹고, 그 줄에 `Claude` 라고 적히면 바로 위의 진짜 Claude 계정
/// 카드와 헷갈린다. docs/design/19-antigravity-usage.md 3-2절
///
/// ```json
/// {"response": {"groups": [
///   {"displayName": "Gemini Models",
///    "buckets": [{"bucketId": "gemini-5h", "window": "5h",
///                 "remainingFraction": 0.38, "resetTime": "2026-09-16T13:01:03Z"}]}]}}
/// ```
public func parseAntigravityUsage(_ data: Data) throws -> [LimitKind: UsageLimit] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw UsageParseError(description: "Antigravity 사용량 응답이 JSON 객체가 아니다")
    }
    let response = root["response"] as? [String: Any] ?? root
    guard let groups = response["groups"] as? [[String: Any]], !groups.isEmpty else { return [:] }

    var out: [LimitKind: UsageLimit] = [:]
    for bucket in buckets(of: geminiGroup(in: groups)) {
        guard let kind = limitKind(window: bucket["window"] as? String),
              let remaining = double(bucket["remainingFraction"]) else { continue }
        // 서버는 잔여를 준다. Claude 와 Codex 는 사용률을 준다. 방향이 반대라
        // 여기서 뒤집어 두면 그 뒤로는 셋이 같은 값을 다룬다
        let used = min(100, max(0, Int(((1 - remaining) * 100).rounded())))
        // 잔여가 가득이면 리셋 시각이 `지금 + 창 길이` 라 읽을 때마다 흐른다.
        // 타이머가 안 걸린 창이므로 없는 것으로 둔다. 18 문서 1-2절과 같은 함정
        let resets = used > 0 ? parseTimestamp(bucket["resetTime"] as? String) : nil
        // 같은 창이 둘이면 앞자리를 둔다. 관측된 적 없는 모양이다
        if out[kind] == nil {
            out[kind] = UsageLimit(percentUsed: used, resetsAt: resets, severity: "")
        }
    }
    return out
}

/// Gemini 묶음. **버킷 이름으로 고른다.**
///
/// `displayName` 은 사람에게 보이라고 있는 문구라 구글이 언제든 바꾼다.
/// `bucketId` 는 프로토콜 쪽 이름이라 덜 흔들린다.
///
/// 못 찾으면 첫째 묶음으로 떨어진다. 이름이 바뀌었을 때 카드가 비는 대신
/// 값이 뜬다. 값이 보이면 사용자가 이상한 것을 알아채지만, 빈 카드는 clf 가
/// 고장 난 것으로만 보인다.
private func geminiGroup(in groups: [[String: Any]]) -> [String: Any] {
    groups.first { group in
        buckets(of: group).contains { ($0["bucketId"] as? String)?.hasPrefix("gemini-") == true }
    } ?? groups[0]
}

private func buckets(of group: [String: Any]) -> [[String: Any]] {
    group["buckets"] as? [[String: Any]] ?? []
}

/// 창 종류를 `window` 필드로 가른다. 모르는 값은 담을 칸이 없어 건너뛴다.
private func limitKind(window: String?) -> LimitKind? {
    switch window {
    case "5h":     return .session
    case "weekly": return .weeklyAll
    default:       return nil
    }
}

/// 플랜 이름. `GetUserStatus` 응답에 있다. 없으면 배지를 안 그린다.
public func parseAntigravityPlan(_ data: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let status = root["userStatus"] as? [String: Any],
          let plan = status["planStatus"] as? [String: Any],
          let info = plan["planInfo"] as? [String: Any] else { return nil }
    return info["planName"] as? String
}

/// `0.38` 로도 `1` 로도 온다.
private func double(_ value: Any?) -> Double? {
    switch value {
    case let d as Double: return d
    case let i as Int:    return Double(i)
    default:              return nil
    }
}

// MARK: 접속 정보

/// 지금 떠 있는 `language_server` 하나.
public struct AntigravityProcess: Sendable, Equatable {
    public let pid: Int32
    public let token: String

    public init(pid: Int32, token: String) {
        self.pid = pid
        self.token = token
    }
}

/// 부를 주소. 포트는 **시도할 차례대로** 담는다. 큰 쪽이 평문 HTTP 다.
public struct AntigravityEndpoint: Sendable, Equatable {
    public let ports: [Int]
    public let token: String

    public init(ports: [Int], token: String) {
        self.ports = ports
        self.token = token
    }
}

/// 앱이 지금 떠 있나, 떠 있으면 어디로 부르나.
///
/// 포트도 CSRF 토큰도 앱을 띄울 때마다 바뀐다. 파일에 없고 프로세스에만 있다.
public protocol AntigravityProbing: Sendable {
    func endpoint() -> AntigravityEndpoint?
}

/// `ps` 출력에서 Antigravity 가 띄운 서버와 그 CSRF 토큰을 캐낸다.
///
/// **앱 번들 안의 것만 잡는다.** `~/.gemini/antigravity-cli/` 의 CLI 도 같은
/// 이름의 서버를 띄우는데 그쪽은 사용량 창구가 아니다.
///
/// 토큰이 없으면 nil 이다. 부를 수 없는 주소를 반쯤 아는 채로 넘기면 부르는
/// 쪽이 그 사실을 또 확인해야 한다.
public func parseAntigravityProcess(psOutput: String) -> AntigravityProcess? {
    for line in psOutput.split(separator: "\n") {
        guard line.contains("Antigravity.app/Contents/Resources/bin/language_server") else {
            continue
        }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let pid = fields.first.flatMap({ Int32($0) }),
              let token = csrfToken(in: fields) else { continue }
        return AntigravityProcess(pid: pid, token: token)
    }
    return nil
}

/// `--csrf_token <값>` 과 `--csrf_token=<값>` 둘 다 받는다.
private func csrfToken(in fields: [Substring]) -> String? {
    for (index, field) in fields.enumerated() {
        if field == "--csrf_token", index + 1 < fields.count {
            return String(fields[index + 1])
        }
        if field.hasPrefix("--csrf_token=") {
            return String(field.dropFirst("--csrf_token=".count))
        }
    }
    return nil
}

/// `lsof -nP -p <pid>` 출력에서 루프백 LISTEN 포트를 **큰 것부터** 돌려준다.
///
/// 서버가 포트 둘을 여는데 실측으로 큰 쪽이 평문 HTTP 다. 작은 쪽으로 평문
/// 요청을 보내면 `Client sent an HTTP request to an HTTPS server` 가 온다.
/// 큰 쪽부터 시도하고 틀리면 남은 포트로 넘어가면 된다.
public func parseLoopbackPorts(lsof: String) -> [Int] {
    var found: Set<Int> = []
    for line in lsof.split(separator: "\n") where line.hasSuffix("(LISTEN)") {
        for host in ["127.0.0.1:", "[::1]:"] {
            guard let range = line.range(of: host) else { continue }
            let digits = line[range.upperBound...].prefix { $0.isNumber }
            if let port = Int(digits) { found.insert(port) }
        }
    }
    return found.sorted(by: >)
}

/// 진짜 `ps` 와 `lsof` 를 돌린다.
public struct LiveAntigravityProbe: AntigravityProbing {
    public init() {}

    public func endpoint() -> AntigravityEndpoint? {
        // `-E` 를 주지 않는다. 필요한 값이 전부 명령줄 인자라 온 기계의
        // 프로세스 환경변수를 우리 메모리로 들일 이유가 없다
        guard let process = parseAntigravityProcess(
            psOutput: run("/bin/ps", ["-A", "-o", "pid=,command="])) else { return nil }
        let ports = parseLoopbackPorts(
            lsof: run("/usr/sbin/lsof", ["-nP", "-p", String(process.pid)]))
        guard !ports.isEmpty else { return nil }
        return AntigravityEndpoint(ports: ports, token: process.token)
    }

    private func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: 네트워크 경계

/// 테스트가 가짜로 갈아끼운다. `UsageFetching` 과 따로 둔다. 저쪽에 얹으면
/// 가짜 구현 전부가 이 메서드를 알아야 한다.
public protocol AntigravityUsageFetching: Sendable {
    func report(port: Int, token: String) async throws -> AntigravityReport
}

public struct LiveAntigravityFetcher: AntigravityUsageFetching {
    /// 앱 이름이 Antigravity 로 바뀌었어도 프로토콜 쪽 이름은 Codeium 시절
    /// 그대로다. 다른 이름을 쓰면 `missing CSRF token` 이 온다
    public static let csrfHeader = "x-codeium-csrf-token"
    static let service = "/exa.language_server_pb.LanguageServerService/"

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) { self.timeout = timeout }

    public func report(port: Int, token: String) async throws -> AntigravityReport {
        let limits = try parseAntigravityUsage(
            try await send("RetrieveUserQuotaSummary", port: port, token: token))
        // 플랜은 배지 하나다. 못 읽었다고 숫자까지 버리지 않는다
        let plan = try? parseAntigravityPlan(
            await send("GetUserStatus", port: port, token: token))
        return AntigravityReport(plan: plan ?? nil, limits: limits)
    }

    private func send(_ rpc: String, port: Int, token: String) async throws -> Data {
        // 평문이다. 루프백이고 CSRF 토큰이 문을 지킨다. HTTPS 쪽은 자체
        // 서명이라 검증을 꺼야 하는데, 검증을 끄는 코드를 두느니 이쪽을 쓴다
        guard let url = URL(string: "http://127.0.0.1:\(port)\(Self.service)\(rpc)") else {
            throw UsageFetchError(description: "Antigravity 주소를 못 만든다")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(token, forHTTPHeaderField: Self.csrfHeader)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is URLError {
            // 루프백이라 회선과 무관하다. 앱이 방금 꺼진 경우가 대부분이다
            throw UsageFetchError(description: "Antigravity 서버에 닿지 못했다")
        }
        // 오류 갈래를 Claude, Codex 와 같게 맞춘다. 같아야 `ReadGate` 와
        // `RefreshPacer` 가 한 자리에서 셋을 다룬다
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            return data
        case 401, 403:
            throw UsageFetchError(description: "Antigravity 가 요청을 거절했다. 앱을 다시 켜면 열쇠가 새로 만들어진다")
        case 429:
            throw UsageFetchError(description: "요청이 너무 잦다. 잠시 뒤 다시 읽는다",
                                  throttled: true)
        case let status:
            throw UsageFetchError(description: "Antigravity RPC HTTP \(status)")
        }
    }
}
