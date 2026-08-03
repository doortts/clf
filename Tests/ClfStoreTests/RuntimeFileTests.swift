import XCTest
import ClfCore
@testable import ClfStore

private let T0 = Date(timeIntervalSince1970: 1_700_000_000)
private func at(_ offset: TimeInterval) -> Date { T0.addingTimeInterval(offset) }
private let day: TimeInterval = 24 * 3600

final class RuntimeFileTests: TempDirTestCase {

    func test_missingFileLoadsAsEmpty() async {
        let loaded = await RuntimeFile(directory: dir).load()
        XCTAssertTrue(loaded.isEmpty)
    }

    /// 런타임은 다시 관측하면 된다. 깨진 파일 하나로 앱이 안 뜨면 안 된다.
    func test_corruptFileLoadsAsEmptyWithoutThrowing() async throws {
        try write("{ nope", to: "runtime.json")
        let loaded = await RuntimeFile(directory: dir).load()
        XCTAssertTrue(loaded.isEmpty)
    }

    func test_roundTripThroughFlush() async throws {
        let file = RuntimeFile(directory: dir)
        let runtime: [AccountID: AccountRuntime] = [
            "a": AccountRuntime(lastUsedAt: at(-100), invalidatedAt: at(-50),
                                modelCooldowns: ["m": at(600)]),
        ]
        await file.schedule(runtime)
        try await file.flush()

        let reloaded = await RuntimeFile(directory: dir).load()
        XCTAssertEqual(reloaded, runtime)
    }

    func test_atomicReplaceOnWrite() async throws {
        let file = RuntimeFile(directory: dir)
        await file.schedule(["a": AccountRuntime(lastUsedAt: at(-1))])
        try await file.flush()
        await file.schedule(["b": AccountRuntime(lastUsedAt: at(-2))])
        try await file.flush()

        XCTAssertEqual(try entries(), ["runtime.json"], "임시 파일이 남지 않는다")
        XCTAssertEqual(try mode("runtime.json"), 0o600)
        let reloaded = await RuntimeFile(directory: dir).load()
        XCTAssertEqual(Set(reloaded.keys), ["b"])
    }

    /// 요청마다 쓰지 않는다. 창 안의 갱신은 마지막 값 하나로 합쳐진다.
    func test_debounceCoalescesWritesAndKeepsLastValue() async throws {
        let file = RuntimeFile(directory: dir, debounce: .milliseconds(80))
        for i in 1...5 {
            await file.schedule(["a": AccountRuntime(lastUsedAt: at(TimeInterval(i)))])
        }
        XCTAssertFalse(exists("runtime.json"), "debounce 창 안에서는 아직 쓰지 않는다")

        try await Task.sleep(for: .milliseconds(300))
        let reloaded = await RuntimeFile(directory: dir).load()
        XCTAssertEqual(reloaded["a"]?.lastUsedAt, at(5))
    }

    func test_flushCancelsPendingDebouncedWrite() async throws {
        let file = RuntimeFile(directory: dir, debounce: .milliseconds(80))
        await file.schedule(["a": AccountRuntime(lastUsedAt: at(1))])
        try await file.flush()

        // flush 가 예약을 정말 죽였는지 보려면 파일을 밖에서 바꿔놓고 기다린다.
        // 유령 쓰기가 남아 있으면 이 값이 덮이고, 없으면 그대로 남는다.
        try write("{}", to: "runtime.json")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(String(decoding: try read("runtime.json"), as: UTF8.self), "{}")
    }

    func test_prunesCooldownsOlderThanSevenDays() async throws {
        let file = RuntimeFile(directory: dir, debounce: .milliseconds(10))
        await file.schedule([
            "a": AccountRuntime(modelCooldowns: [
                "stale": at(-8 * day),      // 7일보다 오래됐다
                "recent": at(-1 * day),     // 만료됐지만 아직 보관 기간 안
                "live": at(600),
            ]),
        ])
        await file.pruneExpiredCooldowns(now: T0)

        let after = await file.snapshot()
        XCTAssertEqual(Set(after["a"]!.modelCooldowns.keys), ["recent", "live"])
    }

    func test_pruneWritesTheResult() async throws {
        let file = RuntimeFile(directory: dir, debounce: .milliseconds(10))
        await file.schedule(["a": AccountRuntime(modelCooldowns: ["stale": at(-8 * day)])])
        await file.pruneExpiredCooldowns(now: T0)
        try await Task.sleep(for: .milliseconds(200))

        let reloaded = await RuntimeFile(directory: dir).load()
        XCTAssertTrue(reloaded["a"]!.modelCooldowns.isEmpty)
    }

    func test_pruneLeavesUntouchedRuntimeAlone() async {
        let file = RuntimeFile(directory: dir)
        let runtime: [AccountID: AccountRuntime] = ["a": AccountRuntime(lastUsedAt: at(-5))]
        await file.schedule(runtime)
        await file.pruneExpiredCooldowns(now: T0)
        let after = await file.snapshot()
        XCTAssertEqual(after, runtime)
    }
}
