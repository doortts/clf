import Foundation

/// 앱의 삭제 표식. `deleted_<id>`, 내용은 삭제 시각(ms)이다.
///
/// 앱은 이 파일을 수동 "CLI 세션 가져오기" 에서만 읽는다. 트랜스크립트를
/// 전수로 훑을 때 무덤에 있는 id 는 지운 것으로 알고 건너뛴다. 목록 표시와는
/// 무관하다. 우리가 레코드를 지울 때 앱과 같은 모양으로 남겨야 가져오기가
/// 지운 대화를 되살리지 않는다. docs/design/15-move-janitor.html 4절
public enum Tombstones {
    static let prefix = "deleted_"

    /// 레코드가 아는 id 전부. 무덤은 이 이름들로 선다.
    ///
    /// 트랜스크립트는 `cliSessionId` 로 조회되지만, clear 를 거친 세션은 옛
    /// 트랜스크립트(`unarchivedCliSessionId`)가 따로 있고, 딥링크로 가져온
    /// 세션은 레코드 이름 자체가 cli id 다. 앱의 삭제가 셋 다 남기므로 우리도
    /// 셋 다 남긴다.
    public static func ids(of record: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: record) as? [String: Any]
        else { return [] }
        var ids: [String] = []
        if let sid = json["sessionId"] as? String, !sid.isEmpty {
            ids.append(sid.hasPrefix(SessionMirror.filePrefix)
                ? String(sid.dropFirst(SessionMirror.filePrefix.count)) : sid)
        }
        for key in ["cliSessionId", "unarchivedCliSessionId"] {
            if let id = json[key] as? String, !id.isEmpty, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// 무덤을 세운다. 못 세워도 조용히 넘어간다. 가져오기가 되살리는 것은
    /// 나중 문제고 옮기기 자체는 이미 성공했다.
    public static func leave(_ ids: [String], in store: SessionStore, at now: Date = Date()) {
        guard FileManager.default.fileExists(atPath: store.root.path) else { return }
        let stamp = Data(String(Int(now.timeIntervalSince1970 * 1000)).utf8)
        for id in ids {
            try? stamp.write(to: store.root.appendingPathComponent(prefix + id))
        }
    }

    /// 무덤을 걷는다. 레코드를 넣는 자리에서 부른다.
    public static func clear(_ ids: [String], in store: SessionStore) {
        for id in ids {
            try? FileManager.default
                .removeItem(at: store.root.appendingPathComponent(prefix + id))
        }
    }
}
