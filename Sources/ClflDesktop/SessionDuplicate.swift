import Foundation

/// 한 대화를 여러 계정이 가리키는 것을 찾는다.
///
/// 11절이 정한 규칙은 **한 대화를 한 계정만 가리키는 것**이다. 그래서 넘기기는
/// 복사가 아니라 옮기기이고, 먼저 넣고 나중에 지운다. 그런데 지금 디스크가 그
/// 규칙을 어기고 있다. 규칙이 주석과 문서에만 있어서 어긴 것을 아무도 잡지
/// 않는다.
///
/// 겹치면 두 창이 같은 트랜스크립트에 쓸 수 있고, 겹친 쪽으로 넘기려 하면
/// 이름이 부딪혀 막힌다. docs/design/13-multi-instance.md 12절
public enum SessionDuplicate {
    /// 한 대화를 가리키는 레코드 하나.
    public struct Owner: Sendable, Equatable {
        public let account: String
        public let fileName: String
        public let transcriptID: String
        /// 이 계정이 마지막으로 이 세션을 움직인 시각. 레코드의
        /// `lastActivityAt` 이라 몇 분 뒤처질 수 있지만, 계정마다 언제까지
        /// 썼는지는 이 값만 안다. 트랜스크립트는 둘이 같이 쓰는 한 파일이다.
        public let lastActivityAt: Date?

        public init(account: String, fileName: String, transcriptID: String,
                    lastActivityAt: Date? = nil) {
            self.account = account
            self.fileName = fileName
            self.transcriptID = transcriptID
            self.lastActivityAt = lastActivityAt
        }
    }

    /// 두 계정 이상이 가리키는 대화 하나.
    public struct Shared: Sendable, Equatable, Identifiable {
        public let transcriptID: String
        public let accounts: [String]
        public var id: String { transcriptID }

        public init(transcriptID: String, accounts: [String]) {
            self.transcriptID = transcriptID
            self.accounts = accounts
        }
    }

    /// 규칙을 어긴 대화만. 지킨 것은 넣지 않는다.
    ///
    /// 한 계정 안에 레코드가 둘이어도 계정은 하나다. 그것은 이 규칙이 다루는
    /// 문제가 아니라서 **계정을 겹치지 않게 센다.**
    public static func find(_ owners: [Owner]) -> [Shared] {
        var byConversation: [String: Set<String>] = [:]
        for owner in owners where !owner.transcriptID.isEmpty {
            byConversation[owner.transcriptID, default: []].insert(owner.account)
        }
        return byConversation
            .filter { $0.value.count >= 2 }
            // 같은 상태가 늘 같게 보여야 한다. 순서를 고정한다
            .map { Shared(transcriptID: $0.key, accounts: $0.value.sorted()) }
            .sorted { $0.transcriptID < $1.transcriptID }
    }

    /// 계정 폴더들을 훑는다. 레코드의 작은 JSON 만 읽는다.
    public static func scan(stores: [SessionStore]) -> [Shared] {
        find(stores.flatMap { store in
            store.records().compactMap { record in
                record.transcriptID.map {
                    Owner(account: store.account, fileName: record.fileName, transcriptID: $0)
                }
            }
        })
    }

    public static let clean = "겹치는 것 없음"

    /// doctor 표에 들어갈 한 칸.
    ///
    /// 상태만 찍지 않고 **무엇을 하면 풀리는지** 같이 적는다. 어느 대화인지도
    /// 말해야 손을 댈 수 있는데, 표 한 칸이라 앞의 몇 개만 적는다.
    ///
    /// uuid 는 앞 8자만 쓴다. 통째로 넣으면 한 줄이 130자를 넘어 표가 깨진다.
    /// 문서도 그 길이로 부른다.
    public static func detail(_ shared: [Shared], limit: Int = 2) -> String {
        guard !shared.isEmpty else { return clean }
        let names = shared.prefix(limit).map { String($0.transcriptID.prefix(8)) }
            .joined(separator: ", ")
        let rest = shared.count - min(limit, shared.count)
        let tail = rest > 0 ? ", 외 \(rest)개" : ""
        return "\(shared.count)개가 여러 계정에 겹쳐 있다 (\(names)\(tail)). 한쪽 레코드를 지운다"
    }
}

// MARK: 지금 쓰이고 있는 겹침. 팝오버 경고가 그린다.

extension SessionDuplicate {
    /// 최근에 썼다고 볼 시간.
    ///
    /// 겹친 레코드 자체는 doctor 가 다룬다. 팝오버는 그중 **지금 움직이는
    /// 대화**만 말해야 한다. 오래된 겹침까지 말하면 경고가 뜻을 잃는다.
    public static let liveWindow: TimeInterval = 15 * 60

    /// 한 계정이 이 대화를 언제까지 썼나. 화면의 한 줄이다.
    public struct Sighting: Sendable, Equatable {
        public let account: String
        public let lastActivityAt: Date?

        public init(account: String, lastActivityAt: Date?) {
            self.account = account
            self.lastActivityAt = lastActivityAt
        }
    }

    /// 여러 계정이 가리키는데 최근에 대화까지 있는 것. 두 창이 한 대화에
    /// 같이 쓸 수 있는 상태다.
    public struct Live: Sendable, Equatable, Identifiable {
        public let transcriptID: String
        /// 계정마다 한 줄. 최근에 쓴 계정이 먼저다.
        public let owners: [Sighting]
        public var id: String { transcriptID }

        public init(transcriptID: String, owners: [Sighting]) {
            self.transcriptID = transcriptID
            self.owners = owners
        }
    }

    /// 겹친 대화 중 최근에 대화한 것만.
    ///
    /// `spokeAt` 은 트랜스크립트의 마지막 대화 시각이다. 레코드의
    /// `lastActivityAt` 으로 거르지 않는 이유는 그 값이 뒤처지기 때문이다.
    /// 실측에서 22:51 로 적혔는데 세션은 22:58 에 일하고 있었다.
    public static func live(_ owners: [Owner], now: Date,
                            within: TimeInterval = liveWindow,
                            spokeAt: (String) -> Date?) -> [Live] {
        var byConversation: [String: [Owner]] = [:]
        for owner in owners where !owner.transcriptID.isEmpty {
            byConversation[owner.transcriptID, default: []].append(owner)
        }
        return byConversation
            .filter { Set($0.value.map(\.account)).count >= 2 }
            .compactMap { id, group -> Live? in
                guard let at = spokeAt(id),
                      // 시계가 어긋나 미래로 찍힐 수 있다. 그것도 최근으로 본다
                      now.timeIntervalSince(at) <= within else { return nil }
                // 한 계정에 레코드가 둘이어도 계정은 한 줄이다. 최근 시각을 남긴다
                var latest: [String: Date?] = [:]
                for owner in group {
                    let known = latest[owner.account] ?? nil
                    if known == nil || (owner.lastActivityAt.map { $0 > known! } ?? false) {
                        latest[owner.account] = owner.lastActivityAt ?? known
                    }
                }
                let sightings = latest
                    .map { Sighting(account: $0.key, lastActivityAt: $0.value) }
                    .sorted {
                        // 최근 것이 먼저, 시각을 모르는 것은 뒤로
                        switch ($0.lastActivityAt, $1.lastActivityAt) {
                        case let (a?, b?) where a != b: return a > b
                        case (_?, nil): return true
                        case (nil, _?): return false
                        default: return $0.account < $1.account
                        }
                    }
                return Live(transcriptID: id, owners: sightings)
            }
            // 같은 상태가 늘 같게 보여야 한다. 순서를 고정한다
            .sorted { $0.transcriptID < $1.transcriptID }
    }

    /// 계정 폴더들을 훑는다. 레코드의 작은 JSON 을 보고, mtime 이 최근인
    /// 트랜스크립트만 뒤쪽을 읽어 대화 시각을 확인한다.
    public static func scanLive(stores: [SessionStore],
                                projects: URL = FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent(".claude/projects"),
                                now: Date = Date()) -> [Live] {
        let fm = FileManager.default
        var owners: [Owner] = []
        for store in stores {
            for name in store.fileNames() {
                guard let data = fm.contents(atPath: store.root.appendingPathComponent(name).path),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let cli = json["cliSessionId"] as? String
                else { continue }
                owners.append(Owner(
                    account: store.account, fileName: name, transcriptID: cli,
                    lastActivityAt: (json["lastActivityAt"] as? Double)
                        .map { Date(timeIntervalSince1970: $0 / 1000) }))
            }
        }
        return live(owners, now: now,
                    spokeAt: { writtenAt($0, projects: projects, now: now) })
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

    // MARK: 트랜스크립트에서 대화 시각 읽기

    /// 트랜스크립트에 마지막으로 대화를 적은 시각. 없으면 `nil`.
    ///
    /// mtime 을 그대로 믿지 않는다. 데스크톱 앱은 창이 떠 있으면 놀고 있는
    /// 세션에도 `last-prompt`, `ai-title` 줄을 계속 덧붙여서, 실측에서 대화가
    /// 00:59 에 끝난 세션의 mtime 이 03:44 로 나왔다. 다만 mtime 은 마지막
    /// 쓰기의 상한이므로, 이미 오래된 파일은 열지 않고 그 값으로 거른다.
    static func writtenAt(_ id: String, projects: URL, now: Date,
                          within: TimeInterval = liveWindow) -> Date? {
        guard let url = SessionMirror.transcriptPath(id, projects: projects),
              let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
                  .modificationDate] as? Date
        else { return nil }
        guard now.timeIntervalSince(mtime) <= within else { return mtime }
        return spokeAt(url)
    }

    /// timestamp 가 있는 마지막 줄의 시각. 대화 줄에만 timestamp 가 있고
    /// 메타데이터 줄에는 없다. 파일이 커도 뒤쪽 256KB 만 읽는다.
    static func spokeAt(_ url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        if size > TranscriptTitle.edgeBytes {
            try? handle.seek(toOffset: UInt64(size - TranscriptTitle.edgeBytes))
        }
        let data = (try? handle.readToEnd()) ?? Data()

        // 줄은 시간 순서라 마지막에 읽힌 것이 최신이다. 잘려서 들어온 첫
        // 줄은 JSON 이 안 되므로 그냥 걸러진다
        var last: Date?
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                  let raw = root["timestamp"] as? String,
                  let at = parse(raw) else { continue }
            last = at
        }
        return last
    }

    /// CLI 는 대개 소수점 초를 붙이지만 안 붙일 때도 있다. 둘 다 받는다.
    static func parse(_ timestamp: String) -> Date? {
        (try? Date(timestamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(timestamp, strategy: .iso8601))
    }

    // MARK: 화면이 쓰는 말

    /// 제목을 못 읽은 세션의 자리 표시.
    public static let untitled = "제목 없는 세션"

    /// 무엇이 문제인가.
    public static let problem = "두 창이 한 대화에 같이 쓰면 기록이 섞일 수 있습니다."
    /// 그래서 무엇을 하면 되는가. 경고만 있고 길이 없으면 사용자가 막힌다.
    public static let advice = "한쪽 계정 창에서 이 세션을 닫으세요."

    /// 계정 줄에 붙는 "어디서 언제까지" 설명. 목록만 있으면 사용자는 어느
    /// 창이 쓰는 중인지 알 수 없다.
    public static func workNote(account: String?, wroteAt: Date?, now: Date) -> String {
        guard let at = wroteAt else { return account ?? "" }
        let minutes = Int(now.timeIntervalSince(at) / 60)
        // 1분 미만이면 아직 일하는 중이다. 미래로 찍힌 시계 어긋남도 같다
        let when = minutes < 1 ? "지금 작업 중" : "\(minutes)분 전까지 작업"
        guard let account, !account.isEmpty else { return when }
        return "\(account) 에서 \(when)"
    }

    /// 겹친 세션들의 제목. 순서는 넣어준 id 순서 그대로다.
    ///
    /// 훑을 때는 제목을 안 읽는다. 여기서도 **겹친 대화만** 읽는다.
    /// 팝오버를 열 때 한 번, 많아야 한두 개다.
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
