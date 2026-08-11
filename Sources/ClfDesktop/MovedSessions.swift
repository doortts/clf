import Foundation
import ClfStore

/// 옮긴 대화의 장부.
///
/// `~/Library/Application Support/clf/moved-sessions.json`. `SharedSessions` 와
/// 같은 자리, 같은 방식이다.
///
/// 옮기기가 지운 레코드를 앱이 종료하며 되살린다(종료 훅의 flush).
/// 디스크만 보면 되살아난 시체와 사용자가 일부러 둔 레코드가 같은 모양이라
/// **지울 때의 활동 시각을 워터마크로 적어 둔다.** 청소부가 이 값과 비교해
/// 시체만 다시 지운다. docs/design/15-move-janitor.html
public struct MovedSessions: Sendable {
    /// 안전핀. 이보다 많이 다시 지웠으면 수동 복원을 먹고 있다는 뜻일 수
    /// 있으니 포기한다.
    public static let cleanLimit = 3

    /// 옮긴 대화 하나.
    public struct Entry: Sendable, Equatable, Codable {
        /// 옛 계정. 여기서 지웠고 여기가 청소 대상이다
        public var from: String
        /// 지울 때 레코드의 `lastActivityAt`. 이보다 최신 활동은 사용자의 일이다
        public var watermark: Double
        /// 다시 지운 횟수
        public var cleaned: Int

        public init(from: String, watermark: Double, cleaned: Int = 0) {
            self.from = from
            self.watermark = watermark
            self.cleaned = cleaned
        }
    }

    private let url: URL

    public init(directory: URL? = nil) throws {
        let base = try directory ?? appSupportDirectory()
        self.url = base.appendingPathComponent("moved-sessions.json")
    }

    public func all() -> [String: Entry] { load() }

    /// 이 대화를 이 계정에서 지웠다.
    ///
    /// 이미 있으면 덮는다. 새 의도가 옛 의도를 이기고, 안전핀도 새로 센다.
    public func note(_ transcriptID: String, from account: String, watermark: Date) {
        var all = load()
        all[transcriptID] = Entry(from: account, watermark: watermark.timeIntervalSince1970)
        save(all)
    }

    public func forget(_ transcriptID: String) {
        var all = load()
        guard all.removeValue(forKey: transcriptID) != nil else { return }
        save(all)
    }

    /// 되살아난 것을 방금 다시 지웠다.
    public func noteCleaned(_ transcriptID: String) {
        var all = load()
        guard var entry = all[transcriptID] else { return }
        entry.cleaned += 1
        all[transcriptID] = entry
        save(all)
    }

    /// 없거나 깨졌으면 빈 장부다.
    private func load() -> [String: Entry] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let all = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return all
    }

    /// 못 적어도 던지지 않는다. 장부는 청소를 돕는 기억이지 옮기기의 일부가
    /// 아니다. 실패하면 좀비가 한 번 더 보일 뿐이다.
    private func save(_ all: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? atomicWrite(data, to: url)
    }
}
