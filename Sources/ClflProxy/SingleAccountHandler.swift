import Foundation
import ClflCore
import ClflStore

/// 요청 직전에 접근 토큰을 낸다.
///
/// 8단계는 저장값을 그대로 쓰고, 9단계의 TokenProvider 가 만료 갱신을 얹으면서
/// 같은 구멍에 꽂힌다. 프록시가 업스트림에 붙이는 것은 두 경우 모두 문자열 하나다.
public protocol AccessTokenProviding: Sendable {
    func accessToken(for id: AccountID) async throws -> String
}

/// 저장된 값을 그대로 낸다. 갱신하지 않는다.
///
/// 만료된 oauth 는 여기서 걸러 이유를 말한다. 그냥 흘려보내면 401 을 맞고
/// 사용자는 왜 안 되는지 알 방법이 없다.
public struct StoredTokenProvider: AccessTokenProviding {
    private let store: any CredentialStoring
    private let now: @Sendable () -> Date

    public init(store: any CredentialStoring,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public func accessToken(for id: AccountID) async throws -> String {
        switch try store.credential(for: id) {
        case .longLived(let token):
            return token
        case .oauth(let json):
            guard let parsed = OAuthCredential(claudeAiOauthJSON: json) else {
                throw TokenUnavailable(accountID: id, reason: "저장된 oauth 블록을 읽지 못했다")
            }
            guard parsed.expiresAt > now() else {
                throw TokenUnavailable(
                    accountID: id,
                    reason: "접근 토큰이 만료됐다. 갱신은 아직 없다. 다시 캡처한다")
            }
            return parsed.accessToken
        }
    }
}

public struct TokenUnavailable: Error, CustomStringConvertible {
    public let accountID: AccountID
    public let reason: String
    public var description: String { "\(accountID): \(reason)" }
}

/// 스왑 없이 조직 하나로만 통과시킨다. 사다리 8칸.
///
/// 여기서 확인하는 것은 스왑 로직이 아니라 **배관**이다. 헤더 재작성이 401 을
/// 부르지 않는지, SSE 가 바이트 그대로 건너가는지, MCP 도구 검색이 살아 있는지.
/// docs/design/08-verification.md 4절
public struct SingleAccountHandler: RequestHandling {
    private let account: Account
    private let tokens: any AccessTokenProviding
    private let executor: any UpstreamExecuting
    private let events: any EventSinking
    private let now: @Sendable () -> Date
    private let trace: @Sendable (RequestTrace) -> Void

    public init(account: Account, tokens: any AccessTokenProviding,
                executor: any UpstreamExecuting, events: any EventSinking,
                now: @escaping @Sendable () -> Date = { Date() },
                trace: @escaping @Sendable (RequestTrace) -> Void = { _ in }) {
        self.account = account
        self.tokens = tokens
        self.executor = executor
        self.events = events
        self.now = now
        self.trace = trace
    }

    public func handle(method: String, uri: String, headers: HeaderBag, body: [UInt8],
                       client: any ClientResponseWriting) async {
        let sessionID = headers["x-claude-session-id"]
        let model = modelName(body)
        let started = now()

        // 요청마다 정확히 하나를 남긴다. 어느 경로로 나가든 여기를 지난다
        var report = TraceBuilder(
            at: started, method: method, uri: uri, model: model,
            sessionID: sessionID, account: account.id, now: now, emit: trace)
        defer { report.finish() }

        let token: String
        do {
            token = try await tokens.accessToken(for: account.id)
        } catch {
            report.failed("자격증명을 쓸 수 없다: \(error)")
            return await fail(client, "자격증명을 쓸 수 없다: \(error)")
        }

        // 순서 고정. strip -> rewriteAuth -> injectVersion
        var upstreamHeaders = ProxyHeaders.stripClientHopByHop(headers)
        upstreamHeaders = ProxyHeaders.rewriteAuth(upstreamHeaders, token: token)
        upstreamHeaders = ProxyHeaders.injectAnthropicVersion(upstreamHeaders)

        let url = ProxyHeaders.buildUpstreamURL(
            baseURL: (account.baseURL ?? defaultAnthropicBaseURL).absoluteString,
            requestURI: uri)

        let attempt: UpstreamAttempt
        do {
            attempt = try await executor.execute(UpstreamRequest(
                url: url, method: method, headers: upstreamHeaders, body: body))
        } catch {
            report.failed("업스트림에 닿지 못했다: \(error)")
            return await fail(client, "업스트림에 닿지 못했다: \(error)")
        }
        report.received(attempt)

        var sniffer = UsageSniffer()
        do {
            let usage = try await relay(attempt, to: client, sniffer: &sniffer)
            record(usage, sessionID: sessionID, body: body)
            report.completed()
        } catch {
            // relay 가 이미 abort 했다. 첫 바이트가 나간 뒤라 덧쓸 것이 없다
            report.aborted()
        }
    }

    /// 아직 한 바이트도 안 나갔을 때만 본문을 쓴다. 누가 낸 오류인지 밝힌다.
    /// 그냥 끊으면 Claude Code 는 네트워크 문제로 보고 사용자는 우리를 의심하지 않는다.
    private func fail(_ client: any ClientResponseWriting, _ message: String) async {
        guard !client.headersSent else { return client.abort() }
        var headers = HeaderBag()
        headers["content-type"] = "application/json"
        client.writeHead(status: 502, headers: headers)

        let payload: [String: Any] = [
            "type": "error",
            "error": ["type": "api_error", "message": "clfl: \(message)"],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        try? await client.write([UInt8](json))
        client.end()
    }

    /// usage 가 없는 응답까지 기록하면 0 짜리 줄만 쌓인다.
    private func record(_ usage: ParsedUsage?, sessionID: SessionID?, body: [UInt8]) {
        guard let usage else { return }
        events.append(UsageRecord(
            ts: now(), account: account.id, model: modelName(body), sessionID: sessionID,
            inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
            cacheCreationInputTokens: usage.cacheCreationInputTokens,
            cacheReadInputTokens: usage.cacheReadInputTokens))
    }

    /// 요청 body 의 `model` 을 그대로 쓴다. 별칭을 우리가 해석하지 않는다.
    private func modelName(_ body: [UInt8]) -> ModelID? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body)),
              let root = object as? [String: Any] else { return nil }
        return root["model"] as? String
    }
}


/// 요청이 흐르는 동안 관측을 모은다.
///
/// 경로가 여럿이라 각 분기에서 손으로 만들면 언젠가 하나가 빠진다.
/// defer 로 한 번만 내보낸다.
private struct TraceBuilder {
    let at: Date
    let method: String
    let uri: String
    let model: ModelID?
    let sessionID: SessionID?
    let account: AccountID?
    let now: @Sendable () -> Date
    let emit: @Sendable (RequestTrace) -> Void

    private var status: Int?
    private var isStreaming = false
    private var bytes = 0
    private var firstByteMillis: Int?
    private var outcome: RequestTrace.Outcome = .failed(reason: "끝나지 않았다")
    private var sent = false

    init(at: Date, method: String, uri: String, model: ModelID?,
         sessionID: SessionID?, account: AccountID?,
         now: @escaping @Sendable () -> Date,
         emit: @escaping @Sendable (RequestTrace) -> Void) {
        self.at = at
        self.method = method
        self.uri = uri
        self.model = model
        self.sessionID = sessionID
        self.account = account
        self.now = now
        self.emit = emit
    }

    mutating func received(_ attempt: UpstreamAttempt) {
        firstByteMillis = millis(since: at)
        switch attempt {
        case .buffered(let code, _, let body, _):
            status = code
            bytes = body.count
        case .streaming(let code, _, let first, let tail, _):
            status = code
            isStreaming = true
            bytes = first.count + tail.count
        }
    }

    /// 릴레이가 끝난 뒤라야 스트림 전체 크기를 안다. buffered 는 그대로다.
    mutating func completed() { outcome = .ok }
    mutating func aborted()   { outcome = .aborted }
    mutating func failed(_ reason: String) { outcome = .failed(reason: reason) }

    mutating func finish() {
        guard !sent else { return }
        sent = true
        emit(RequestTrace(
            at: at, method: method, uri: uri, model: model, sessionID: sessionID,
            account: account, status: status, isStreaming: isStreaming, bytes: bytes,
            firstByteMillis: firstByteMillis, totalMillis: millis(since: at),
            outcome: outcome))
    }

    private func millis(since start: Date) -> Int {
        Int(now().timeIntervalSince(start) * 1000)
    }
}
