import XCTest
import ClfCore
@testable import ClfProxy

private let T0 = Date(timeIntervalSince1970: 1_700_000_000)

/// 요청 하나의 판단 과정. audit.jsonl 은 사건을 남기고 이것은 과정을 남긴다.
/// docs/design/08-verification.md 5절
final class RequestTraceTests: XCTestCase {

    func trace(
        account: AccountID? = "team1",
        model: ModelID? = "claude-opus-4-5",
        sessionID: SessionID? = "sess-1",
        status: Int? = 200,
        streaming: Bool = true,
        bytes: Int = 4096,
        outcome: RequestTrace.Outcome = .ok
    ) -> RequestTrace {
        RequestTrace(at: T0, method: "POST", uri: "/v1/messages",
                     model: model, sessionID: sessionID, account: account,
                     status: status, isStreaming: streaming, bytes: bytes,
                     firstByteMillis: 840, totalMillis: 3200, outcome: outcome)
    }

    // MARK: 한 줄 표시

    /// 실기기 확인에서 이 한 줄이 관측의 전부다. 무엇이 빠지면 안 보인다.
    func test_lineCarriesEverythingWorthWatching() {
        let line = trace().line
        for needle in ["POST", "/v1/messages", "team1", "200", "opus", "sess-1", "840"] {
            XCTAssertTrue(line.contains(needle), "\(needle) 이 없다: \(line)")
        }
    }

    func test_marksStreamingVersusBuffered() {
        XCTAssertTrue(trace(streaming: true).line.contains("SSE"))
        XCTAssertFalse(trace(streaming: false).line.contains("SSE"))
    }

    /// 세션 id 가 오는지가 8단계에서 확인할 항목이다. 없으면 없다고 말해야 한다.
    func test_saysWhenSessionIdIsMissing() {
        XCTAssertTrue(trace(sessionID: nil).line.contains("세션없음"))
    }

    func test_failureLineSaysWhy() {
        let line = trace(status: nil, outcome: .failed(reason: "업스트림에 닿지 못했다")).line
        XCTAssertTrue(line.contains("업스트림에 닿지 못했다"), line)
    }

    /// 첫 바이트가 나간 뒤 끊긴 것은 실패와 다르다. 사용자는 반쯤 받았다.
    func test_abortedIsDistinctFromFailed() {
        XCTAssertTrue(trace(outcome: .aborted).line.contains("중단"))
    }

    // MARK: JSON

    /// 컨트롤 플레인이 같은 레코드를 낸다. 두 경로로 갈리면 설명이 거짓말한다.
    func test_jsonCarriesTheSameFacts() throws {
        let data = try JSONSerialization.data(withJSONObject: trace().jsonObject)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["account"] as? String, "team1")
        XCTAssertEqual(root["status"] as? Int, 200)
        XCTAssertEqual(root["model"] as? String, "claude-opus-4-5")
        XCTAssertEqual(root["session_id"] as? String, "sess-1")
        XCTAssertEqual(root["outcome"] as? String, "ok")
        XCTAssertEqual(root["first_byte_ms"] as? Int, 840)
    }

    func test_jsonOmitsUnknownFieldsRatherThanFaking() throws {
        let sparse = trace(model: nil, sessionID: nil, status: nil,
                           outcome: .failed(reason: "x")).jsonObject
        XCTAssertNil(sparse["model"])
        XCTAssertNil(sparse["session_id"])
        XCTAssertNil(sparse["status"], "모르는 것을 0 으로 적으면 안 된다")
        XCTAssertEqual(sparse["outcome"] as? String, "failed")
    }

    // MARK: 링 버퍼

    /// 진단용이라 무한히 쌓을 이유가 없다. 오래된 것부터 버린다.
    func test_ringBufferKeepsMostRecent() {
        let ring = TraceRing(capacity: 3)
        for i in 1...5 { ring.append(trace(account: "a\(i)")) }
        XCTAssertEqual(ring.recent().map(\.account), ["a3", "a4", "a5"])
    }

    func test_ringBufferLimitsWhatItReturns() {
        let ring = TraceRing(capacity: 10)
        for i in 1...5 { ring.append(trace(account: "a\(i)")) }
        XCTAssertEqual(ring.recent(limit: 2).map(\.account), ["a4", "a5"])
    }

    func test_emptyRing() {
        XCTAssertTrue(TraceRing(capacity: 3).recent().isEmpty)
    }
}
