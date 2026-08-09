import Foundation
import ClfStore

/// 일부러 공유해 둔 대화의 장부.
///
/// `~/Library/Application Support/clf/shared-sessions.json`. `HandoffGrace` 와
/// 같은 자리, 같은 방식이다.
///
/// **디스크만 보고 알아낼 수 없다.** 레코드가 두 폴더에 있으면 공유처럼 보이지만
/// 이전하다 만 찌꺼기도 같은 모양이다. 겹침 경고를 켤지 말지가 그 구별에 달려서
/// 의도를 따로 적는다. docs/design/14-shared-session.md
public struct SharedSessions: Sendable {
    /// 대화 하나의 공유 상태.
    public struct Entry: Sendable, Equatable, Codable {
        /// 이 대화를 공유하는 계정. 둘 이상이다
        public var accounts: [String]
        /// 처음 공유한 시각
        public var sharedAt: Double
        /// **우리가 그 계정에 써 넣은 `lastActivityAt`.** 겹침 판정이 이 값을 보고
        /// 동기화가 만든 가짜 활동을 뺀다
        public var mirrored: [String: Double]

        public init(accounts: [String], sharedAt: Double, mirrored: [String: Double] = [:]) {
            self.accounts = accounts
            self.sharedAt = sharedAt
            self.mirrored = mirrored
        }
    }

    private let url: URL

    public init(directory: URL? = nil) throws {
        let base = try directory ?? appSupportDirectory()
        self.url = base.appendingPathComponent("shared-sessions.json")
    }

    public func all() -> [String: Entry] { load() }

    /// 이 대화를 이 계정들이 같이 본다.
    ///
    /// 이미 있으면 계정을 합친다. 덮어쓰면 앞서 공유한 계정을 잃는다.
    /// 처음 공유한 시각은 그대로 둔다.
    public func share(_ transcriptID: String, accounts: [String], at now: Date = Date()) {
        var all = load()
        var merged = Set(all[transcriptID]?.accounts ?? [])
        merged.formUnion(accounts)
        // 계정 하나는 공유가 아니다. 적으면 유령 항목이 된다
        guard merged.count >= 2 else { return }
        all[transcriptID] = Entry(accounts: merged.sorted(),
                                  sharedAt: all[transcriptID]?.sharedAt
                                      ?? now.timeIntervalSince1970,
                                  mirrored: all[transcriptID]?.mirrored ?? [:])
        save(all)
    }

    public func forget(_ transcriptID: String) {
        var all = load()
        guard all.removeValue(forKey: transcriptID) != nil else { return }
        save(all)
    }

    /// 방금 이 계정에 이 값을 써 넣었다.
    public func noteMirror(_ transcriptID: String, account: String, activityAt: Date) {
        var all = load()
        guard var entry = all[transcriptID] else { return }
        entry.mirrored[account] = activityAt.timeIntervalSince1970
        all[transcriptID] = entry
        save(all)
    }

    /// 그 계정에서 레코드가 사라졌다.
    ///
    /// 하나만 남으면 공유가 아니므로 항목을 지운다. 남겨 두면 경고 규칙이
    /// 없는 공유를 계속 본다.
    public func drop(account: String, from transcriptID: String) {
        var all = load()
        guard var entry = all[transcriptID] else { return }
        entry.accounts.removeAll { $0 == account }
        entry.mirrored[account] = nil
        if entry.accounts.count >= 2 { all[transcriptID] = entry } else { all[transcriptID] = nil }
        save(all)
    }

    /// 겹침 판정에 넘길 값. 대화마다, 계정마다 우리가 써 넣은 시각.
    public func mirrorStamps() -> [String: [String: Date]] {
        load().mapValues { $0.mirrored.mapValues { Date(timeIntervalSince1970: $0) } }
    }

    /// 없거나 깨졌으면 빈 장부다. 장부 하나 때문에 공유가 앱을 멈추면 안 된다.
    private func load() -> [String: Entry] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let all = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return all
    }

    /// **못 적어도 던지지 않는다.** 공유 자체는 디스크의 레코드가 정하고 장부는
    /// 의도만 기억한다. 실패하면 상태 맞추기가 한 번 안 도는 정도다.
    private func save(_ all: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? atomicWrite(data, to: url)
    }
}
