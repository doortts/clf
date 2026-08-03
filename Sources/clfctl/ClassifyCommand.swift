import Foundation
import ArgumentParser
import ClfCore

/// 응답 하나를 분류기에 그대로 먹인다.
///
/// 429 를 실제로 맞았을 때 우리가 그것을 어떻게 읽는지 미리 확인하는 자리다.
/// curl 로 받아둔 헤더와 본문을 그대로 넣으면 된다.
struct Classify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "상태 코드와 헤더, 본문을 분류기에 먹인다",
        discussion: """
        헤더는 -H 를 여러 번 준다.

          clfctl classify --status 429 \\
            -H 'retry-after: 42' \\
            -H 'anthropic-ratelimit-unified-reset: 1800000000'

          clfctl classify --status 200 --sse-file first-frame.txt
        """)

    @Option(help: "HTTP 상태 코드") var status: Int
    @Option(name: .customShort("H"), parsing: .upToNextOption,
            help: "헤더. 'name: value' 형식") var header: [String] = []
    @Option(name: .customLong("body-file"), help: "비스트리밍 본문 파일") var bodyFile: String?
    @Option(name: .customLong("sse-file"), help: "peek 한 첫 SSE 프레임 파일") var sseFile: String?
    @Option(help: "조직 id") var account: String = "team1"

    func run() async throws {
        var bag = HeaderBag()
        for raw in header {
            guard let colon = raw.firstIndex(of: ":") else {
                throw CheckFailed(description: "헤더 형식이 아니다: \(raw)")
            }
            bag[String(raw[raw.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)] =
                String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        var body: Data?
        if let bodyFile { body = try Data(contentsOf: URL(fileURLWithPath: bodyFile)) }

        var firstEvent: SSEEvent?
        if let sseFile {
            let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: sseFile)))
            firstEvent = parseFirstSSEEvent(bytes)
            guard firstEvent != nil else {
                throw CheckFailed(description: "SSE 프레임을 하나도 읽지 못했다")
            }
        }

        let now = Int(Date().timeIntervalSince1970)
        let input = ClassifyInput(
            status: status, headers: bag, body: body, firstSSEEvent: firstEvent,
            accountID: account, sessionID: "cli", now: now)
        let errorType = extractErrorType(input)
        let trigger = classifyResponse(input)

        print("  상태    \(status)")
        if let firstEvent {
            print("  첫프레임 event=\(firstEvent.event) data=\(firstEvent.data.prefix(120))")
        }
        // 상태 코드만으로는 절대 판정하지 않는다. 본문의 error.type 이 없으면
        // 429 든 401 이든 통과다. 그 사실을 감추면 도구가 거짓말을 한다
        print("  error.type \(errorType ?? "없음 (본문을 못 읽었거나 Anthropic 형태가 아니다)")")
        print()
        guard let trigger else {
            print("  판정    스왑 대상 아님. 그대로 통과시킨다")
            if errorType == nil && (status == 429 || status == 401) {
                print("  참고:   본문 없이 상태 코드만으로는 스왑하지 않는다.")
                print("          --body-file 이나 --sse-file 로 본문을 준다")
            }
            return
        }
        switch trigger {
        case .rateLimit(_, let reset, _):
            print("  판정    rate_limit. 이 모델만 막는다")
            printReset(reset, now: now)
            print("  일시과부하 \(isTransientOverload(headers: bag, trigger: trigger) ? "예 (5초 후 재시도)" : "아니오")")
        case .sessionLimit(_, let reset, _):
            print("  판정    session_limit. 계정 전체를 막는다")
            printReset(reset, now: now)
        case .authentication:
            print("  판정    authentication. oauth 면 갱신 1회 후 같은 조직으로 재시도한다")
        case .poolExhausted:
            print("  판정    poolExhausted. 분류기는 이걸 만들지 않는다")
        }
    }

    private func printReset(_ epoch: Int, now: Int) {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        print("  해제    \(stamp(date)) (\(epoch - now)초 뒤)")
    }
}
