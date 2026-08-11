import Foundation

/// 옮긴 자리의 청소부.
///
/// 옮기기가 지운 레코드를 앱이 종료 flush 로 되살린다. 장부(`MovedSessions`)의
/// 대화만 보고, 되살아난 레코드를 워터마크와 비교해 시체만 다시 지운다.
///
/// **창이 떠 있는 동안은 아무것도 안 지운다.** 화면의 줄은 앱 메모리라 디스크를
/// 지워도 효과가 없고, 앱의 쓰기와 얽히면 결과를 예측할 수 없다. 창이 없으면
/// 되살릴 프로세스가 없어 한 번 지우면 끝난다.
/// docs/design/15-move-janitor.html
public enum MoveJanitor {
    /// 옛 자리에 되살아난 레코드.
    public struct Resurrected: Sendable, Equatable {
        public let activityAt: Date?
        public init(activityAt: Date?) { self.activityAt = activityAt }
    }

    public enum Verdict: Sendable, Equatable {
        /// 정상. 항목은 남긴다. 되살림은 며칠 뒤에도 온다
        case leaveAlone
        /// 창이 떠 있다. 이번 바퀴는 넘어간다
        case skipWindowUp
        /// 청소부의 일이 아니게 됐다. 장부에서만 뺀다
        case dropEntry
        /// 되살아난 시체다. 지우고 무덤을 남기고 안전핀을 센다
        case clean
    }

    /// 판정. 파일은 안 건드린다. 7절 흐름도 그대로다.
    ///
    /// 헷갈리면 안 지운다. 시각을 모르는 레코드도 물러난다. 틀려서 안 지우면
    /// 겹침 표시가 남을 뿐이고, 틀려서 지우면 사용자 상태를 잃는다.
    public static func judge(shared: Bool,
                             otherSideHasRecord: Bool,
                             windowUp: Bool,
                             resurrected: Resurrected?,
                             watermark: Date,
                             cleaned: Int) -> Verdict {
        // 앞의 두 문은 삭제가 아니라 장부 정리라 창과 무관하게 안전하다
        if shared { return .dropEntry }
        if !otherSideHasRecord { return .dropEntry }
        if windowUp { return .skipWindowUp }
        guard let resurrected else { return .leaveAlone }
        guard let at = resurrected.activityAt, at <= watermark else { return .dropEntry }
        guard cleaned < MovedSessions.cleanLimit else { return .dropEntry }
        return .clean
    }

    /// 장부의 대화를 쓸어낸다. 다음 바퀴에 넘길 폴더 기억을 돌려준다.
    ///
    /// 비용 순서로 문을 세운다. 공유 확인(집합 조회), 창 확인(집합 조회),
    /// 폴더 mtime(stat), 그다음에야 파일을 읽는다. 조용한 폴더는 stat 에서
    /// 끝난다. 창이 떠 있는 계정의 기억은 **갱신하지 않는다.** 그 사이의
    /// 변화를 창이 닫힌 뒤에 봐야 하기 때문이다.
    @discardableResult
    public static func sweep(ledger: MovedSessions,
                             sharedIDs: Set<String>,
                             stores: [String: [SessionStore]],
                             windowsUp: Set<String>,
                             lastSeen: [String: Date] = [:],
                             now: Date = Date()) -> [String: Date] {
        var seen = lastSeen
        for (transcriptID, entry) in ledger.all() {
            if sharedIDs.contains(transcriptID) { ledger.forget(transcriptID); continue }
            guard let fromStores = stores[entry.from], !fromStores.isEmpty else { continue }
            if windowsUp.contains(entry.from) { continue }

            // 폴더가 그대로면 파일 하나 안 연다. 기억은 지금 값을 적는다.
            // 우리 삭제가 mtime 을 움직이므로 다음 바퀴에 한 번 더 보고 잠잠해진다
            let marks = folderMarks(of: fromStores)
            let quiet = marks.allSatisfy { path, mark in lastSeen[path] == mark }
            for (path, mark) in marks { seen[path] = mark }
            if quiet { continue }

            let corpses = fromStores.compactMap { store in
                store.recordFile(of: transcriptID).map { (store, $0) }
            }
            let others = stores.contains { account, sites in
                account != entry.from && sites.contains { $0.recordFile(of: transcriptID) != nil }
            }
            // 자리가 여럿이면 가장 최신 시각으로 판정한다. 하나라도 진짜
            // 작업이면 물러나야 한다. 전부 시각이 없으면 모르는 것이다
            let resurrected = corpses.isEmpty ? nil
                : Resurrected(activityAt: corpses.compactMap(\.1.activityAt).max())

            switch judge(shared: false, otherSideHasRecord: others, windowUp: false,
                         resurrected: resurrected,
                         watermark: Date(timeIntervalSince1970: entry.watermark),
                         cleaned: entry.cleaned) {
            case .dropEntry:
                ledger.forget(transcriptID)
            case .clean:
                for (store, corpse) in corpses {
                    try? FileManager.default
                        .removeItem(at: store.root.appendingPathComponent(corpse.fileName))
                    Tombstones.leave(Tombstones.ids(of: corpse.data), in: store, at: now)
                }
                ledger.noteCleaned(transcriptID)
            case .leaveAlone, .skipWindowUp:
                break
            }
        }
        return seen
    }

    /// 계정 자리들의 폴더 mtime. 테스트가 게이트를 닫는 데도 쓴다.
    public static func folderMarks(stores: [String: [SessionStore]]) -> [String: Date] {
        var all: [String: Date] = [:]
        for sites in stores.values {
            for (path, mark) in folderMarks(of: sites) { all[path] = mark }
        }
        return all
    }

    private static func folderMarks(of sites: [SessionStore]) -> [String: Date] {
        var marks: [String: Date] = [:]
        for store in sites {
            guard let mtime = (try? FileManager.default
                .attributesOfItem(atPath: store.root.path))?[.modificationDate] as? Date
            else { continue }
            marks[store.root.path] = mtime
        }
        return marks
    }
}

extension SessionStore {
    /// 이 자리에서 그 대화를 가리키는 레코드. 없으면 `nil`.
    func recordFile(of transcriptID: String)
        -> (fileName: String, data: Data, activityAt: Date?)? {
        let fm = FileManager.default
        for name in fileNames() {
            guard let data = fm.contents(atPath: root.appendingPathComponent(name).path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["cliSessionId"] as? String == transcriptID
            else { continue }
            return (name, data, (json["lastActivityAt"] as? Double)
                .map { Date(timeIntervalSince1970: $0 / 1000) })
        }
        return nil
    }
}

