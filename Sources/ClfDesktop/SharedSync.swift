import Foundation

/// 공유한 대화의 레코드를 최신본으로 맞춘다.
///
/// 레코드에는 대화 본문 말고도 창별 상태가 들어 있다. 제목, 턴 수, `model`,
/// `effort`, `permissionMode` 다. 두 계정이 각자 갱신하면 갈라지고, 옛 사본에서
/// 열면 그때 저장된 설정으로 재개된다.
///
/// **언제 도느냐가 설계의 절반이다.** 레코드는 턴마다 바뀌는데 그 변화가 뜻을
/// 가지는 순간은 계정을 바꿀 때뿐이라, 파일 변경을 좇지 않고 볼 사람이 생기는
/// 순간에 맞춘다. 창을 띄우기 직전과 5초 감시 루프 둘이다.
/// docs/design/14-shared-session.md 5절
public enum SharedSync {
    /// 한 계정이 가진 이 대화의 레코드.
    public struct Side: Sendable, Equatable {
        public let account: String
        public let fileName: String
        public let lastActivityAt: Date?

        public init(account: String, fileName: String, lastActivityAt: Date?) {
            self.account = account
            self.fileName = fileName
            self.lastActivityAt = lastActivityAt
        }
    }

    /// 이 최신본을 이 계정에 덮는다.
    public struct Copy: Sendable, Equatable {
        public let from: Side
        public let to: String

        public init(from: Side, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// 무엇을 덮을지 정한다. 파일은 안 건드린다.
    ///
    /// 문은 둘이고 **둘 다 쓰기를 막는 자리다.**
    ///
    /// - 창이 떠 있는 계정에만 쓴다. 창이 없으면 그 목록을 읽을 프로세스가
    ///   없어서 지금 맞출 이유가 없다. 이 문이 없으면 한 계정으로 일하는 내내
    ///   턴마다 반대쪽 폴더에 쓴다
    /// - 대상이 더 최신이거나 같으면 안 쓴다. 같은 것까지 쓰면 우리가 넣은 값을
    ///   다음 바퀴에 다시 최신으로 보고 두 폴더를 무한히 오간다
    ///
    /// 시각을 모르는 레코드는 옛것으로 친다. 받는 쪽은 되지만 주는 쪽은 안 된다.
    /// 최신이라고 말하려면 언제 썼는지를 댈 수 있어야 한다.
    public static func plan(_ sides: [Side], windowsUp: Set<String>) -> [Copy] {
        // 한 계정에 레코드가 둘이어도 계정은 하나다. 최신 것만 본다
        var newest: [String: Side] = [:]
        for side in sides {
            guard let known = newest[side.account] else { newest[side.account] = side; continue }
            let mine = side.lastActivityAt ?? .distantPast
            if mine > (known.lastActivityAt ?? .distantPast) { newest[side.account] = side }
        }
        // 시각이 같으면 계정 이름으로 정한다. 누가 원본이 되든 결과는 같지만
        // 같은 상태가 늘 같게 돌아야 한다
        guard newest.count >= 2,
              let source = newest.values
                .filter({ $0.lastActivityAt != nil })
                .sorted(by: {
                    $0.lastActivityAt! == $1.lastActivityAt!
                        ? $0.account < $1.account
                        : $0.lastActivityAt! > $1.lastActivityAt!
                })
                .first
        else { return [] }

        return newest.values
            .filter { $0.account != source.account && windowsUp.contains($0.account) }
            .filter { ($0.lastActivityAt ?? .distantPast) < source.lastActivityAt! }
            // 같은 상태가 늘 같게 돌아야 한다. 순서를 고정한다
            .sorted { $0.account < $1.account }
            .map { Copy(from: source, to: $0.account) }
    }

    /// 실제로 맞춘다. 덮은 수를 돌려준다.
    ///
    /// `stores` 는 계정마다의 자리다. 기본 데이터 디렉토리에 하나, 그 계정으로
    /// 띄운 별도 창이 있으면 하나 더다. 자리를 다 맞춰야 남은 창이 옛것을
    /// 보여주지 않는다.
    @discardableResult
    public static func run(_ ledger: SharedSessions,
                           stores: [String: [SessionStore]],
                           windowsUp: Set<String>) -> Int {
        let fm = FileManager.default
        var copied = 0
        for (transcriptID, entry) in ledger.all() {
            // 계정마다 자리를 다 훑는다. 같은 대화라도 자리별로 파일 이름이 다르고
            // 아직 레코드가 없는 자리도 있다
            var seats: [String: [Seat]] = [:]
            for account in entry.accounts {
                let sites = stores[account] ?? []
                // 우리가 모르는 계정은 판단하지 않는다. 없다고 단정하면 멀쩡한
                // 공유가 목록에서 사라진다
                guard !sites.isEmpty else { continue }
                let found = sites.map { store in
                    let hit = record(of: transcriptID, in: store)
                    return Seat(store: store, fileName: hit?.fileName, at: hit?.at)
                }
                // 어느 자리에도 없으면 그 계정은 이 대화를 지웠다. 계정을 빼고,
                // 하나만 남으면 항목이 사라진다. 목록에만 남으면 유령이다
                if found.allSatisfy({ $0.fileName == nil }) {
                    ledger.drop(account: account, from: transcriptID)
                } else {
                    seats[account] = found
                }
            }

            let sides = seats.flatMap { account, found in
                found.compactMap { seat in
                    seat.fileName.map {
                        Side(account: account, fileName: $0, lastActivityAt: seat.at)
                    }
                }
            }
            for copy in plan(sides, windowsUp: windowsUp) {
                guard let source = seats[copy.from.account]?
                        .first(where: { $0.fileName == copy.from.fileName }),
                      let data = fm.contents(atPath: source.store.root
                        .appendingPathComponent(copy.from.fileName).path)
                else { continue }

                for seat in seats[copy.to] ?? [] {
                    // **이름은 대상 것을 지킨다.** local_<sessionId>.json 의
                    // sessionId 는 레코드 고유값이라 계정마다 다르고, 이름을 같이
                    // 바꾸면 앱이 목록에서 그 줄을 잃는다. 아직 레코드가 없는
                    // 자리에만 원본 이름을 쓴다
                    try? fm.createDirectory(at: seat.store.root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
                    try? data.write(to: seat.store.root
                        .appendingPathComponent(seat.fileName ?? copy.from.fileName))
                }
                if let at = copy.from.lastActivityAt {
                    ledger.noteMirror(transcriptID, account: copy.to, activityAt: at)
                }
                copied += 1
            }
        }
        return copied
    }

    /// 한 계정의 자리 하나. 레코드가 아직 없으면 `fileName` 이 `nil` 이다.
    private struct Seat {
        let store: SessionStore
        let fileName: String?
        let at: Date?
    }

    /// 이 자리에서 그 대화를 가리키는 레코드. 없으면 `nil`.
    private static func record(of transcriptID: String, in store: SessionStore)
        -> (fileName: String, at: Date?)? {
        let fm = FileManager.default
        for name in store.fileNames() {
            guard let data = fm.contents(atPath: store.root.appendingPathComponent(name).path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["cliSessionId"] as? String == transcriptID
            else { continue }
            return (name, (json["lastActivityAt"] as? Double)
                .map { Date(timeIntervalSince1970: $0 / 1000) })
        }
        return nil
    }
}
