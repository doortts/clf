import Foundation

/// 한 작업 폴더를 세션 여럿이 쓰고 있는 것을 찾는다.
///
/// 세션은 계정을 건너갈 수 있지만 **작업 트리는 안 갈라진다.** 같은 폴더에
/// 세션이 둘 이상 붙어 있으면 서로 남의 파일을 고칠 수 있다. 실제로 이
/// 저장소에서 세션 셋이 한 폴더에 붙어 커밋 안 된 변경이 세 갈래로 쌓인 일이
/// 있었다. 넘기기는 그 상황을 못 막는다. 레코드만 옮기고 체크아웃은 그대로
/// 두기 때문이다. docs/design/13-multi-instance.md 12절
public enum FolderOverlap {
    /// 최근에 썼다고 볼 시간.
    ///
    /// **레코드가 있다고 살아 있는 세션이 아니다.** 지난 세션까지 세면 오래
    /// 쓴 폴더는 늘 겹친 것으로 보이고 그러면 경고가 뜻을 잃는다.
    public static let liveWindow: TimeInterval = 15 * 60

    /// 세션 하나가 어느 폴더를 언제 썼나.
    public struct Use: Sendable, Equatable {
        /// cliSessionId. 겹쳤을 때 제목을 찾아가는 열쇠다.
        public let id: String
        public let cwd: String
        /// 트랜스크립트에 마지막으로 쓴 시각.
        ///
        /// 레코드의 `lastActivityAt` 을 쓰지 않는다. 실측에서 그 값이 22:51 인데
        /// 세션은 22:58 에 일하고 있었다. 파일 mtime 이 살아 있는 신호다.
        public let wroteAt: Date?

        public init(id: String = "", cwd: String, wroteAt: Date?) {
            self.id = id
            self.cwd = cwd
            self.wroteAt = wroteAt
        }
    }

    /// 세션이 둘 이상 붙어 있는 폴더.
    public struct Folder: Sendable, Equatable, Identifiable {
        public let path: String
        /// 겹친 세션들. 최근에 쓴 것이 먼저다. 개수만 보여주면 무엇인지
        /// 모르므로 화면은 이 id 로 제목을 찾아 보여준다.
        public let sessionIDs: [String]
        public var sessions: Int { sessionIDs.count }
        public var id: String { path }

        public init(path: String, sessionIDs: [String]) {
            self.path = path
            self.sessionIDs = sessionIDs
        }

        /// 화면에 쓸 이름. 경로 전체는 팝오버 폭에 안 들어간다.
        public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    /// 겹치는 폴더만. 하나뿐인 폴더는 넣지 않는다.
    ///
    /// 겹치는 일이 없으면 빈 배열이고, 그러면 화면은 이 묶음을 아예 안
    /// 보여준다. 평소에 조용해야 진짜 겹쳤을 때 눈에 띈다.
    public static func find(_ uses: [Use], now: Date,
                            within: TimeInterval = liveWindow) -> [Folder] {
        var byFolder: [String: [(id: String, at: Date)]] = [:]
        for use in uses {
            // 경로를 모르면 셀 수 없다. 트랜스크립트가 없으면 쓴 적이 없다
            guard !use.cwd.isEmpty, let at = use.wroteAt else { continue }
            // 시계가 어긋나 미래로 찍힐 수 있다. 그것도 최근으로 본다
            guard now.timeIntervalSince(at) <= within else { continue }
            byFolder[use.cwd, default: []].append((use.id, at))
        }
        return byFolder
            .filter { $0.value.count >= 2 }
            .map { path, entries in
                Folder(path: path, sessionIDs: entries.sorted { $0.at > $1.at }.map(\.id))
            }
            .sorted { $0.sessions != $1.sessions ? $0.sessions > $1.sessions : $0.path < $1.path }
    }

    // MARK: 화면이 쓰는 말

    /// 제목을 못 읽은 세션의 자리 표시.
    public static let untitled = "제목 없는 세션"

    /// 무엇이 문제인가.
    public static let problem = "같은 폴더의 세션은 서로 남의 변경을 덮을 수 있습니다."
    /// 그래서 무엇을 하면 되는가. 경고만 있고 길이 없으면 사용자가 막힌다.
    /// 마지막 문장은 아래 세션 넘기기 단추로 해결하려는 오해를 막는다.
    public static let advice = "한 세션만 남기고 닫거나 세션마다 작업 폴더를 나누세요. 세션 넘기기를 해도 두 세션은 같은 폴더를 계속 씁니다."

    /// 겹친 세션들의 제목. 순서는 넣어준 id 순서 그대로다.
    ///
    /// 훑을 때(scan) 제목을 안 읽는 것과 같은 이유로, 여기서도 **겹친 폴더의
    /// 세션만** 읽는다. 팝오버를 열 때 한 번, 많아야 서너 개다.
    public static func titles(ids: [String],
                              projects: URL = FileManager.default.homeDirectoryForCurrentUser
                                  .appendingPathComponent(".claude/projects")) -> [String] {
        ids.map { id in
            guard let url = SessionMirror.transcriptPath(id, projects: projects) else {
                return untitled
            }
            let title = TranscriptTitle.of(url)
            return title.isEmpty ? untitled : title
        }
    }
}

extension FolderOverlap {
    /// 계정 폴더들을 훑어 겹치는 폴더를 찾는다.
    ///
    /// **제목은 안 읽는다.** 팝오버는 5초마다 도는데 세션마다 트랜스크립트
    /// 양끝 256KB 를 읽으면 너무 비싸다. 여기서는 레코드의 작은 JSON 과 파일
    /// mtime 만 본다.
    public static func scan(stores: [SessionStore],
                            projects: URL = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent(".claude/projects"),
                            now: Date = Date()) -> [Folder] {
        let fm = FileManager.default
        var uses: [Use] = []
        // 같은 대화가 계정 폴더 여럿에 있을 수 있다. 그것을 둘로 세면
        // 겹치지도 않은 폴더가 겹친 것으로 보인다
        var seen = Set<String>()

        for store in stores {
            for name in store.fileNames() {
                guard let data = fm.contents(atPath: store.root.appendingPathComponent(name).path),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let cli = json["cliSessionId"] as? String,
                      seen.insert(cli).inserted
                else { continue }

                uses.append(Use(id: cli,
                                cwd: json["cwd"] as? String ?? json["originCwd"] as? String ?? "",
                                wroteAt: writtenAt(cli, projects: projects)))
            }
        }
        return find(uses, now: now)
    }

    /// 트랜스크립트에 마지막으로 쓴 시각. 없으면 `nil`.
    static func writtenAt(_ id: String, projects: URL) -> Date? {
        guard let url = SessionMirror.transcriptPath(id, projects: projects) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    /// 이 데이터 디렉토리가 가진 계정 폴더 전부.
    ///
    /// 계정 목록을 몰라도 된다. 디렉토리 이름이 곧 계정이라 읽으면 나온다.
    public static func stores(inside dataDirectory: URL) -> [SessionStore] {
        guard let person = SessionStore.person(in: dataDirectory) else { return [] }
        let base = dataDirectory
            .appendingPathComponent(SessionStore.baseDir, isDirectory: true)
            .appendingPathComponent(person, isDirectory: true)
        let accounts = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return accounts
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { SessionStore(dataDirectory: dataDirectory, person: person, account: $0) }
    }
}
