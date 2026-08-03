import Foundation
import ClfCore

/// runtime.json. 조직별 런타임 상태 전체.
///
/// 재시작마다 잃으면 소진된 (조직, 모델) 쌍을 다시 프로브해 429 캐스케이드를
/// 반복하고, 401 로 무효화한 조직이 되살아나고, 5시간 쿨다운이 리셋되고, UI 게이지가
/// 첫 요청 전까지 빈다. docs/design/02-domain-model.md 6절
///
/// 쓰기는 1초 debounce 로 합친다. 요청마다 쓰지 않는다.
public actor RuntimeFile {
    /// 이보다 오래된 modelCooldowns 항목은 시작 시 정리한다.
    public static let cooldownRetention: TimeInterval = 7 * 24 * 3600

    private let url: URL
    private let debounce: Duration
    private var current: [AccountID: AccountRuntime] = [:]
    private var pendingWrite: Task<Void, Never>?
    /// 마지막 쓰기 실패. 삼키되 진단 화면이 볼 수 있게 남긴다.
    public private(set) var lastWriteError: String?

    public init(directory: URL, debounce: Duration = .seconds(1)) {
        self.url = directory.appendingPathComponent("runtime.json")
        self.debounce = debounce
    }

    /// 읽기 실패는 치명적이지 않다. 빈 런타임으로 시작한다.
    public func load() -> [AccountID: AccountRuntime] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let loaded = try? makeDecoder().decode([AccountID: AccountRuntime].self, from: data)
        else {
            current = [:]
            return [:]
        }
        current = loaded
        return loaded
    }

    /// debounce 대상. 즉시 쓰지 않고 예약한다.
    ///
    /// 창이 열려 있는 동안 들어온 값은 전부 current 에 겹쳐 쓰이므로 마지막 값 하나만
    /// 디스크로 간다. 예약이 이미 있으면 새로 걸지 않는다.
    public func schedule(_ runtime: [AccountID: AccountRuntime]) {
        current = runtime
        guard pendingWrite == nil else { return }
        pendingWrite = Task { [debounce] in
            // 취소를 삼키면 안 된다. try? 로 넘기면 flush 가 막 쓴 파일 위로
            // 취소된 타이머가 한 번 더 쓴다.
            do { try await Task.sleep(for: debounce) } catch { return }
            // Task 가 액터 격리를 물려받으므로 직접 호출이다
            self.writeCurrent()
        }
    }

    /// 종료 시퀀스에서 부른다.
    ///
    /// 예약된 쓰기를 취소하고 그 태스크가 끝날 때까지 기다린 다음 쓴다. 기다리지
    /// 않으면 이미 sleep 을 지나 액터를 기다리던 태스크가 flush 뒤에 한 번 더 쓴다.
    public func flush() async throws {
        pendingWrite?.cancel()
        await pendingWrite?.value
        pendingWrite = nil
        try atomicWrite(makeEncoder().encode(current), to: url)
        lastWriteError = nil
    }

    /// 7일 지난 modelCooldowns 항목을 정리한다. 시작 시퀀스에서 부른다.
    public func pruneExpiredCooldowns(now: Date) {
        let floor = now.addingTimeInterval(-Self.cooldownRetention)
        var changed = false
        for (id, var runtime) in current {
            let kept = runtime.modelCooldowns.filter { $0.value >= floor }
            guard kept.count != runtime.modelCooldowns.count else { continue }
            runtime.modelCooldowns = kept
            current[id] = runtime
            changed = true
        }
        if changed { schedule(current) }
    }

    /// 테스트와 UI 가 현재 값을 본다.
    public func snapshot() -> [AccountID: AccountRuntime] { current }

    private func writeCurrent() {
        pendingWrite = nil
        do {
            try atomicWrite(makeEncoder().encode(current), to: url)
            lastWriteError = nil
        } catch {
            lastWriteError = String(describing: error)
        }
    }
}
