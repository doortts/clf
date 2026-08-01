import Foundation
import ArgumentParser
import ClflCore
import ClflStore
import ClflProxy

struct Upstream: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "실제 업스트림 왕복",
        subcommands: [Probe.self])

    /// 사다리 7칸의 통과 기준. 여기가 처음으로 api.anthropic.com 에 붙는다.
    ///
    /// 확인하는 것은 세 가지다. 헤더 재작성이 401 을 부르지 않는가,
    /// 압축 자동 해제가 켜져 있어 SSE peek 이 평문을 보는가, 사용량 헤더가
    /// 실제로 오는가. docs/design/08-verification.md 4절
    struct Probe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "조직 하나로 실제 요청을 한 번 보낸다",
            discussion: """
            토큰 한 글자도 출력하지 않는다. 왕복 결과와 사용량 헤더만 보여준다.

              clflctl upstream probe naver_team_40
              clflctl upstream probe naver_team_40 --stream
            """)

        @OptionGroup var paths: Paths

        @Argument(help: "등록된 조직 id") var id: String
        @Option(help: "요청 모델") var model: String = "claude-opus-4-5"
        @Flag(help: "스트리밍으로 보낸다. SSE peek 경로를 탄다") var stream = false
        @Flag(help: "런타임에 사용량 읽기를 저장한다") var save = false

        func run() async throws {
            let executor = HTTPUpstreamExecutor()
            do {
                try await probe(executor)
            } catch {
                // async defer 가 없다. 어느 경로로 나가든 클라이언트를 닫는다
                await executor.shutdown()
                throw error
            }
            await executor.shutdown()
        }

        private func probe(_ executor: HTTPUpstreamExecutor) async throws {
            let doc = try await paths.accountsFile().load()
            guard let account = doc.accounts[id] else {
                throw CheckFailed(description: "\(id) 는 등록돼 있지 않다. clflctl accounts list")
            }
            let token = try accessToken(for: account)

            // stripClientHopByHop -> rewriteAuth -> injectAnthropicVersion 순서 고정
            var headers = ProxyHeaders.stripClientHopByHop(HeaderBag())
            headers["content-type"] = "application/json"
            headers = ProxyHeaders.rewriteAuth(headers, token: token)
            headers = ProxyHeaders.injectAnthropicVersion(headers)

            let body = requestBody()
            let url = ProxyHeaders.buildUpstreamURL(
                baseURL: (account.baseURL ?? defaultAnthropicBaseURL).absoluteString,
                requestURI: "/v1/messages")

            print("  조직    \(id) (\(account.plan.rawValue), \(account.credentialKind.rawValue))")
            print("  대상    \(url)")
            print("  인증    " + (headers["authorization"] != nil
                                  ? "Authorization: Bearer + anthropic-beta"
                                  : "x-api-key"))
            print("  모드    \(stream ? "스트리밍" : "버퍼")")
            print()

            let started = Date()
            let attempt: UpstreamAttempt
            do {
                attempt = try await executor.execute(UpstreamRequest(
                    url: url, method: "POST", headers: headers, body: body))
            } catch {
                throw CheckFailed(description: "업스트림에 붙지 못했다: \(error)")
            }
            let elapsed = Date().timeIntervalSince(started)

            let status: Int
            let responseHeaders: HeaderBag
            let trigger: SwapTrigger?

            switch attempt {
            case .buffered(let s, let h, let received, _):
                status = s
                responseHeaders = h
                print("  응답    \(s), \(received.count) 바이트, \(String(format: "%.2f", elapsed))초")
                trigger = classifyResponse(ClassifyInput(
                    status: s, headers: h, body: Data(received),
                    accountID: id, sessionID: "probe",
                    now: Int(Date().timeIntervalSince1970)))
                if s != 200 {
                    print("  본문    \(String(decoding: received.prefix(400), as: UTF8.self))")
                }

            case .streaming(let s, let h, let first, let tail, let rest):
                status = s
                responseHeaders = h
                let event = parseFirstSSEEvent(first)
                print("  응답    \(s), 첫 프레임 \(first.count) 바이트, "
                      + "\(String(format: "%.2f", elapsed))초")
                print("  첫프레임 event=\(event?.event ?? "-")")
                // 평문이 아니면 압축 해제가 꺼진 것이다. 이 확인이 probe 의 핵심
                print("  평문    " + (event != nil ? "예" : "아니오 (압축 해제를 의심한다)"))
                trigger = classifyResponse(ClassifyInput(
                    status: s, headers: h, firstSSEEvent: event,
                    accountID: id, sessionID: "probe",
                    now: Int(Date().timeIntervalSince1970)))

                var relayed = tail.count
                while let chunk = try await rest.next() { relayed += chunk.readableBytes }
                print("  잔여    \(relayed) 바이트를 끝까지 읽었다")
            }

            print()
            printUsage(responseHeaders)

            if let trigger {
                print()
                print("  판정    스왑 대상: \(describe(trigger))")
            }

            if save, let snapshot = rateLimitSnapshot(from: responseHeaders, now: Date()) {
                let file = try paths.runtimeFile()
                var runtime = await file.load()
                var entry = runtime[id] ?? AccountRuntime()
                entry.rateLimit = snapshot
                entry.lastUsedAt = Date()
                runtime[id] = entry
                await file.schedule(runtime)
                try await file.flush()
                print("  런타임에 저장했다. clflctl runtime show 로 확인한다")
            }

            guard status == 200 else {
                throw CheckFailed(description: "200 이 아니다. 7단계는 통과가 아니다")
            }
        }

        /// 최소 요청. 토큰을 태우지 않으려고 출력을 1로 묶는다.
        private func requestBody() -> [UInt8] {
            let payload: [String: Any] = [
                "model": model,
                "max_tokens": 1,
                "stream": stream,
                "messages": [["role": "user", "content": "hi"]],
            ]
            return [UInt8](try! JSONSerialization.data(withJSONObject: payload))
        }

        /// 갱신하지 않는다. 갱신은 9단계의 TokenProvider 몫이다.
        /// 만료된 oauth 는 조용히 401 을 맞는 대신 여기서 이유를 말한다.
        private func accessToken(for account: Account) throws -> String {
            switch try paths.credentials.credential(for: account.id) {
            case .longLived(let token):
                return token
            case .oauth(let json):
                guard let parsed = OAuthCredential(claudeAiOauthJSON: json) else {
                    throw CheckFailed(description: "저장된 oauth 블록을 읽지 못했다")
                }
                if parsed.expiresAt < Date() {
                    throw CheckFailed(description: """
                    접근 토큰이 \(stamp(parsed.expiresAt)) 에 만료됐다.
                    갱신은 아직 없다(9단계). claude auth login 후 다시 캡처한다.
                    """)
                }
                return parsed.accessToken
            }
        }

        private func printUsage(_ headers: HeaderBag) {
            guard let snapshot = rateLimitSnapshot(from: headers, now: Date()) else {
                print("  사용량  헤더에 없다. 이 응답으로는 잔여를 알 수 없다")
                return
            }
            print(renderTable(["창", "잔여", "리셋"], [
                ["5시간", percent(snapshot.fiveHour?.remaining),
                 stamp(snapshot.fiveHour?.resetsAt)],
                ["주간", percent(snapshot.sevenDayAll?.remaining),
                 stamp(snapshot.sevenDayAll?.resetsAt)],
            ]))
            print("  모델별 주간은 헤더에 없다. Usage API 를 불러야 한다")
        }

        private func describe(_ trigger: SwapTrigger) -> String {
            switch trigger {
            case .rateLimit(_, let reset, _):
                return "rate_limit, \(stamp(Date(timeIntervalSince1970: TimeInterval(reset)))) 해제"
            case .sessionLimit(_, let reset, _):
                return "session_limit, \(stamp(Date(timeIntervalSince1970: TimeInterval(reset)))) 해제"
            case .authentication:
                return "authentication"
            case .poolExhausted:
                return "poolExhausted"
            }
        }
    }
}
