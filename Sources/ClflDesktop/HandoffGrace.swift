import Foundation
import ClflStore

/// 넘긴 직후의 겹침은 경고하지 않는다.
///
/// 넘기면 옛 창이 세션을 여전히 쥐고 있어 레코드가 되살아나고, 그 순간
/// 두 계정이 같은 대화를 가리킨다. 그건 사용자가 방금 스스로 한 일이라
/// 경고하면 혼란만 준다. 옛 창을 재시작하거나 세션이 정리될 시간을 주고,
/// 그 뒤에도 겹쳐 있으면 그때는 진짜 겹침이다.
///
/// `~/Library/Application Support/clfl/handoff-grace.json`
/// 앱이 재시작해도 참을 것은 계속 참아야 해서 파일에 적는다.
public struct HandoffGrace: Sendable {
    /// 참아줄 시간. 경고의 liveWindow 와 같은 15분이다.
    public static let window: TimeInterval = 15 * 60

    private let url: URL

    public init(directory: URL? = nil) throws {
        let base = try directory ?? appSupportDirectory()
        self.url = base.appendingPathComponent("handoff-grace.json")
    }

    /// 방금 이 대화를 넘겼다.
    ///
    /// **못 적어도 넘기기는 성공이다.** 장부는 경고를 참는 데만 쓰이므로
    /// 실패하면 경고가 한 번 더 보일 뿐이다. 그래서 던지지 않는다.
    public func note(_ transcriptID: String, at now: Date = Date()) {
        var all = load()
        all[transcriptID] = now.timeIntervalSince1970
        // 지난 항목은 적을 때 지운다. 파일이 자라기만 하면 안 된다
        all = all.filter { now.timeIntervalSince1970 - $0.value < Self.window }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? atomicWrite(data, to: url)
    }

    /// 지금 경고를 참아야 하는 대화들.
    public func muted(now: Date = Date()) -> Set<String> {
        Set(load()
            .filter { now.timeIntervalSince1970 - $0.value < Self.window }
            .keys)
    }

    /// 없거나 깨졌으면 빈 장부다. 장부 하나 때문에 경고가 멎으면 안 된다.
    private func load() -> [String: Double] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let all = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return all
    }
}
