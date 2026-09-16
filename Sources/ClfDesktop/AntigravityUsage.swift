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
    for bucket in buckets(of: geminiGroup(in: groups) ?? [:]) {
        guard let kind = limitKind(window: bucket["window"] as? String) else { continue }
        // **키가 없을 때만 0 이다.** protobuf JSON 은 기본값을 안 싣는다. 다 쓴
        // 창은 `remainingFraction` 이 통째로 빠진 채로 온다. 그 버킷을 건너뛰면
        // 한도를 다 쓴 바로 그 순간에 카드가 옛 숫자를 내밀고 알림이 침묵한다.
        //
        // 키가 있는데 못 읽는 값이면 건너뛴다. 그것까지 0 으로 읽으면 80% 남은
        // 계정에 소진 알림이 나간다. 사라진 줄은 사용자가 알아채지만 거짓
        // 소진은 알아챌 방법이 없다
        let raw = bucket["remainingFraction"]
        let parsed = double(raw)
        if raw != nil, parsed == nil { continue }
        let remaining = parsed ?? 0
        // 잔여가 가득이면 리셋 시각이 `지금 + 창 길이` 라 읽을 때마다 흐른다.
        // 타이머가 안 걸린 창이므로 없는 것으로 둔다. 18 문서 1-2절과 같은 함정.
        // **판정은 반올림 전 값으로 한다.** 정수로 보면 0.4% 쓴 창이 안 열린
        // 창으로 둔갑한다
        let resets = remaining < 1 ? parseTimestamp(bucket["resetTime"] as? String) : nil
        let used = usedPercent(remaining: remaining)
        // 같은 창이 둘이면 앞자리를 둔다. 관측된 적 없는 모양이다
        if out[kind] == nil {
            out[kind] = UsageLimit(percentUsed: used, resetsAt: resets, severity: "")
        }
    }
    return out
}

/// 잔여 비율을 사용률 정수로. 서버는 잔여를 주고 Claude 와 Codex 는 사용률을
/// 준다. 여기서 뒤집어 두면 그 뒤로는 셋이 같은 값을 다룬다.
///
/// **0 과 100 은 진짜 양 끝에서만 나온다.** 조금이라도 썼으면 1 이상이고
/// 조금이라도 남았으면 99 이하다. 그냥 반올림하면 0.4% 쓴 창이 `창 안 열림`
/// 이 되고, 0.4% 남은 창이 소진 알림을 띄운다. 둘 다 거짓말이다.
func usedPercent(remaining: Double) -> Int {
    let used = 1 - remaining
    if used <= 0 { return 0 }
    // 부등호를 뒤집어 NaN 도 여기서 걸린다. `Int(nan)` 은 프로세스를 죽인다
    if !(used < 1) { return 100 }
    return min(99, max(1, Int((used * 100).rounded())))
}

/// Gemini 묶음. **버킷 이름으로 고른다.**
///
/// `displayName` 은 사람에게 보이라고 있는 문구라 구글이 언제든 바꾼다.
/// `bucketId` 는 프로토콜 쪽 이름이라 덜 흔들린다.
///
/// 못 찾으면 첫째 묶음으로 떨어진다. 이름이 바뀌었을 때 카드가 비는 대신
/// 값이 뜬다. 값이 보이면 사용자가 이상한 것을 알아채지만, 빈 카드는 clf 가
/// 고장 난 것으로만 보인다.
private func geminiGroup(in groups: [[String: Any]]) -> [String: Any]? {
    if let named = groups.first(where: { hasBucket($0, prefix: "gemini-") }) { return named }
    // 떨어질 때도 3p 주머니는 고르지 않는다. 다른 주머니 숫자에 `Gemini` 배지를
    // 달아 내보내면 그냥 거짓말이다. 남는 묶음이 없으면 빈 카드가 낫다
    return groups.first { !hasBucket($0, prefix: "3p-") }
}

/// 그 묶음에 이런 이름의 버킷이 있나. **버킷 전체를 본다.** 첫 버킷만 보면
/// 차례가 뒤집히거나 앞에 다른 이름이 끼는 날 3p 묶음을 못 알아본다.
private func hasBucket(_ group: [String: Any], prefix: String) -> Bool {
    buckets(of: group).contains { ($0["bucketId"] as? String)?.hasPrefix(prefix) == true }
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

/// `ps` 출력에서 Antigravity 가 띄운 서버들을 **새 것부터** 캐낸다.
///
/// **목록으로 준다.** 앱이 비정상 종료하면 자식 서버가 고아로 남고, 다음에
/// 앱을 켜면 둘이 보인다. 첫 줄만 보고 죽은 쪽을 고르면 카드가
/// `꺼져 있다` 로 굳고 유일한 안내인 `켜기` 단추를 눌러도 안 고쳐진다.
/// 부르는 쪽이 포트가 잡히는 후보까지 내려간다.
///
/// **실행 파일이 그 서버인 줄만 잡는다.** 명령줄에 경로가 스쳐 간 줄
/// (`/bin/sh -c ... language_server ...`) 은 아니다. `~/.gemini/antigravity-cli/`
/// 의 CLI 서버도 경로가 달라 여기서 걸러진다.
public func parseAntigravityProcesses(psOutput: String) -> [AntigravityProcess] {
    psOutput.split(separator: "\n")
        .compactMap(parseServerLine)
        // 새 프로세스가 먼저다. 고아는 앱보다 먼저 떴으므로 pid 가 작다
        .sorted { $0.pid > $1.pid }
}

/// `  2608 /경로/language_server --csrf_token abc ...` 한 줄.
private func parseServerLine(_ line: Substring) -> AntigravityProcess? {
    let rest = line.drop { $0 == " " }
    let digits = rest.prefix { $0.isNumber }
    guard let pid = Int32(digits) else { return nil }
    let command = rest.dropFirst(digits.count).drop { $0 == " " }
    // 실행 파일은 첫 ` -` 앞까지다. 경로에 공백이 있어도 안 끊기고, 인자 사이
    // 공백이 둘이어도 꼬리를 털어서 맞춘다.
    //
    // **경로에 ` -` 가 든 앱은 못 알아본다.** `ps` 는 argv 를 공백 하나로 이어
    // 붙이므로 `/apps -old/...` 와 `/bin/sh -c ...` 가 글자로는 같은 모양이다.
    // 둘 중 하나만 고를 수 있어서 안전한 쪽을 골랐다. 못 알아보면 카드가
    // `꺼져 있다` 로 남지만, 반대로 하면 명령줄에 경로가 스쳐 간 아무 줄이나
    // 서버로 믿고 엉뚱한 토큰으로 두드린다
    let head = command.range(of: " -").map { command[..<$0.lowerBound] } ?? command[...]
    let executable = head.reversed().drop { $0 == " " }.reversed().map(String.init).joined()
    guard executable.hasSuffix("Antigravity.app/Contents/Resources/bin/language_server"),
          let token = csrfToken(in: command.split(separator: " ",
                                                  omittingEmptySubsequences: true))
    else { return nil }
    return AntigravityProcess(pid: pid, token: token)
}

/// `--csrf_token <값>` 과 `--csrf_token=<값>` 둘 다 받는다.
///
/// 값이 빠져 다음 플래그가 붙어 오면 없는 것으로 본다. 그 플래그를 토큰으로
/// 삼으면 서버가 401 을 내고 우리는 이유를 엉뚱한 데서 찾는다.
private func csrfToken(in fields: [Substring]) -> String? {
    for (index, field) in fields.enumerated() {
        if field == "--csrf_token", index + 1 < fields.count,
           !fields[index + 1].hasPrefix("-") {
            return trimmed(fields[index + 1])
        }
        if field.hasPrefix("--csrf_token=") {
            return trimmed(field.dropFirst("--csrf_token=".count))
        }
    }
    return nil
}

/// 이 값이 HTTP 헤더 값이 된다. 눈에 안 보이는 글자가 붙으면 안 된다.
private func trimmed(_ value: Substring) -> String? {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

/// `lsof -nP -p <pid>` 출력에서 루프백 LISTEN 포트를 **큰 것부터** 돌려준다.
///
/// 서버가 포트 둘을 여는데 실측으로 큰 쪽이 평문 HTTP 다. 작은 쪽으로 평문
/// 요청을 보내면 `Client sent an HTTP request to an HTTPS server` 가 온다.
/// 큰 쪽부터 시도하고 틀리면 남은 포트로 넘어가면 된다.
public func parseLoopbackPorts(lsof: String) -> [Int] {
    var found: Set<Int> = []
    for raw in lsof.split(separator: "\n") {
        // 꼬리 공백이나 CR 하나에 빗나가면 앱이 도는데 꺼졌다고 적게 된다
        let line = raw.drop { $0 == " " }.reversed().drop { $0.isWhitespace }
            .reversed().map(String.init).joined()
        guard line.hasSuffix("(LISTEN)") else { continue }
        // 와일드카드도 받는다. 이미 pid 로 대상을 좁혔고, 서버가 듀얼스택으로
        // 바뀌면 `*:` 로 나오는데 못 읽으면 포트가 빈 배열이 된다
        for host in ["127.0.0.1:", "[::1]:", "*:"] {
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
        // `ps` 는 이 기계에서 0.15초다. 시한을 넉넉히 줘서 느린 날 잘린 목록을
        // 옳은 목록으로 착각하지 않는다
        guard let listing = Shell.run("/bin/ps", ["-A", "-o", "pid=,command="], timeout: 30)
        else { return nil }
        // 포트가 잡히는 후보까지 내려간다. 고아 프로세스는 LISTEN 이 없다.
        // 고아가 쌓여도 읽기 한 번이 길어지지 않게 셋에서 끊는다
        for server in parseAntigravityProcesses(psOutput: listing).prefix(3) {
            // `-w` 는 경고를 끄고 `-S` 는 lsof 가 커널에서 막힐 때 스스로
            // 포기하게 한다. **`-S` 가 진짜 방어다.** lsof 는 블록을 깨려고
            // 자식을 띄우는데, 그 자식이 우리 출력 파이프를 물려받은 채 멈추면
            // 부모를 죽여도 파이프가 안 닫혀 우리 쪽 시한이 소용없다
            let ports = Shell.run("/usr/sbin/lsof",
                                  ["-nP", "-w", "-S", "3", "-p", String(server.pid)])
                .map(parseLoopbackPorts) ?? []
            if !ports.isEmpty {
                return AntigravityEndpoint(ports: ports, token: server.token)
            }
        }
        return nil
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
