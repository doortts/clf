import Foundation

/// 작업 폴더가 사라진 레코드를 치운다.
///
/// worktree 를 지우면 그 자리에서 하던 대화의 레코드만 남는다. 열어도 갈 자리가
/// 없으니 목록에 둘 이유가 없다. 경고로 적어 두면 지워지지 않고 계속 쌓인다.
///
/// **대화를 지우는 것이 아니다.** 레코드는 `~/.claude/projects` 의 트랜스크립트를
/// 가리키는 작은 포인터라, 지워도 기록은 그대로 있고 `claude --resume` 으로
/// 이어갈 수 있다. 지운 자리에는 옮기기와 같은 무덤을 남긴다. 무덤이 없으면
/// 앱의 "CLI 세션 가져오기" 가 다음번에 좀비로 되살린다.
/// docs/design/15-move-janitor.html 4절
public enum StaleSessions {
    /// 훑고 지운다. 지운 대화 id 를 돌려준다.
    ///
    /// 공유해 둔 대화도 예외가 아니다. 양쪽 레코드가 같이 지워지므로 공유
    /// 장부에서도 뺀다. 남겨 두면 없는 공유를 계속 맞추려 든다.
    ///
    /// **창이 떠 있는지는 보지 않는다.** 앱이 종료하며 되살리면 다음 바퀴에
    /// 다시 지운다. 그 사이에도 목록은 `summaries` 가 걸러서 조용하다.
    @discardableResult
    public static func sweep(stores: [SessionStore],
                             shared: SharedSessions? = nil,
                             folderExists: (String) -> Bool = {
                                 FileManager.default.fileExists(atPath: $0)
                             },
                             now: Date = Date()) -> [String] {
        let fm = FileManager.default
        var gone: [String] = []
        for store in stores {
            for name in store.fileNames() {
                let url = store.root.appendingPathComponent(name)
                guard let data = fm.contents(atPath: url.path),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let cwd = json["cwd"] as? String ?? json["originCwd"] as? String ?? ""
                // 경로를 모르는 레코드는 그냥 둔다. 짐작으로 지우면 되돌릴 수 없다
                guard !cwd.isEmpty, !folderExists(cwd) else { continue }
                try? fm.removeItem(at: url)
                Tombstones.leave(Tombstones.ids(of: data), in: store, at: now)
                if let cli = json["cliSessionId"] as? String, !cli.isEmpty { gone.append(cli) }
            }
        }
        if !gone.isEmpty {
            let ledger = shared ?? (try? SharedSessions())
            for id in Set(gone) { ledger?.forget(id) }
        }
        return gone
    }
}
