import XCTest
import ClflCore
@testable import ClflStore

private let T0 = Date(timeIntervalSince1970: 1_700_000_000)

private func usage(_ input: Int) -> UsageRecord {
    UsageRecord(ts: T0, account: "team1", model: "claude-opus-4-5", sessionID: "s1",
                inputTokens: input, outputTokens: 2,
                cacheCreationInputTokens: 3, cacheReadInputTokens: 4)
}

final class JSONLSinkTests: TempDirTestCase {

    func lines(_ name: String) throws -> [[String: Any]] {
        String(decoding: try read(name), as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func test_appendsOnePerLineAndKeepsOrder() throws {
        let sink = JSONLSink(directory: dir)
        for i in 1...5 { sink.append(usage(i)) }
        sink.drain()

        let rows = try lines("usage.jsonl")
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map { $0["input_tokens"] as? Int }, [1, 2, 3, 4, 5])
    }

    /// 캐시 두 필드를 반드시 남긴다. 스왑이 유발한 캐시 재생성 비용을 뽑는 유일한 근거다.
    func test_usageSchemaMatchesTheDocumentedShape() throws {
        let sink = JSONLSink(directory: dir)
        sink.append(usage(1))
        sink.drain()

        let row = try XCTUnwrap(try lines("usage.jsonl").first)
        XCTAssertEqual(Set(row.keys),
                       ["ts", "account", "model", "session_id", "input_tokens", "output_tokens",
                        "cache_creation_input_tokens", "cache_read_input_tokens"])
        XCTAssertEqual(row["ts"] as? String, "2023-11-14T22:13:20Z")
    }

    func test_eventsAndUsageGoToSeparateFiles() throws {
        let sink = JSONLSink(directory: dir)
        sink.append(usage(1))
        sink.append(RoutingEvent(at: T0, sessionID: "s1",
                                 kind: .swap(from: "a", to: "b", trigger: "rate_limit",
                                             crossPlan: false)))
        sink.drain()

        XCTAssertEqual(try lines("usage.jsonl").count, 1)
        XCTAssertEqual(try lines("audit.jsonl").count, 1)
    }

    func test_appendsToExistingFileRatherThanReplacingIt() throws {
        let first = JSONLSink(directory: dir)
        first.append(usage(1))
        first.drain()

        let second = JSONLSink(directory: dir)
        second.append(usage(2))
        second.drain()

        XCTAssertEqual(try lines("usage.jsonl").map { $0["input_tokens"] as? Int }, [1, 2])
    }

    func test_createsFileWithOwnerOnlyMode() throws {
        let sink = JSONLSink(directory: dir)
        sink.append(usage(1))
        sink.drain()
        XCTAssertEqual(try mode("usage.jsonl"), 0o600)
    }

    /// 디스크가 가득 차서 로그를 못 써도 프록시는 계속 돌아야 한다.
    /// 규율이 아니라 타입으로 강제하므로 여기서는 던지지 않는 것만 확인한다.
    func test_unwritableDirectoryDoesNotCrashOrThrow() {
        let sink = JSONLSink(directory: URL(fileURLWithPath: "/dev/null/nope"))
        sink.append(usage(1))
        sink.append(RoutingEvent(at: T0, sessionID: nil, kind: .poolExhausted(lastTried: "a")))
        sink.drain()
    }

    func test_nullSinkSwallowsEverything() {
        let sink = NullEventSink()
        sink.append(usage(1))
        sink.append(RoutingEvent(at: T0, sessionID: nil, kind: .accountInvalidated("a")))
    }
}
