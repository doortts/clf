import Foundation

/// 목록에 뜨는 세션 이름.
///
/// 제목은 트랜스크립트 안에 있다. 세션 레코드에는 제목 필드가 없다.
/// 앱은 `customTitle` 을 `aiTitle` 보다 먼저 보고, 둘 다 나중 것이 이긴다.
public enum TranscriptTitle {
    /// 양끝에서 읽을 크기. **파일을 통째로 안 읽는다.** 73MB 짜리도 있다.
    public static let edgeBytes = 256 * 1024

    public static func of(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            .flatMap { $0 } ?? 0

        var chunks: [Data] = []
        if size <= edgeBytes * 2 {
            chunks = [(try? handle.readToEnd()) ?? Data()]
        } else {
            chunks.append((try? handle.read(upToCount: edgeBytes)) ?? Data())
            try? handle.seek(toOffset: UInt64(size - edgeBytes))
            chunks.append((try? handle.readToEnd()) ?? Data())
        }

        // 뒤쪽이 최신이므로 뒤부터 본다
        var custom = "", ai = ""
        let newline = UInt8(ascii: "\n")
        for chunk in chunks {
            for line in chunk.split(separator: newline, omittingEmptySubsequences: true) {
                guard let root = try? JSONSerialization.jsonObject(with: Data(line))
                        as? [String: Any] else { continue }
                if let t = root["customTitle"] as? String, !t.isEmpty { custom = t }
                if let t = root["aiTitle"] as? String, !t.isEmpty { ai = t }
            }
        }
        return custom.isEmpty ? ai : custom
    }
}

/// 세션을 다른 계정으로 옮긴다.
///
/// **트랜스크립트는 손대지 않는다.** 420바이트짜리 레코드 파일 하나를 계정
/// 폴더 사이로 옮기는 것이 전부다. 대화는 `~/.claude/projects` 에 그대로 있고
/// 계정 귀속은 레코드가 어느 폴더에 있느냐로만 정해진다.
///
/// 복사가 아니라 옮기기인 이유는 **한 계정만 그 대화를 가리키게** 하려는
/// 것이다. 둘이 가리키면 두 창이 같은 트랜스크립트에 쓸 수 있다.
/// docs/design/13-multi-instance.md
public enum SessionHandoff {

    /// 대상에 같은 이름이 있으면 덮으면 안 된다. 저쪽이 먼저 쓰던 것이다.
    public static func collides(_ fileName: String, in target: [String]) -> Bool {
        target.contains(fileName)
    }

    public static func canMove(from source: String, to target: String) -> Bool {
        source != target
    }

    public enum Failure: Error, CustomStringConvertible {
        case sameAccount
        case collision(String)
        case missing(String)
        case io(String)

        public var description: String {
            switch self {
            case .sameAccount:        return "같은 계정이다"
            case .collision(let n):   return "\(n) 이 대상 계정에 이미 있다"
            case .missing(let n):     return "\(n) 을 못 찾았다"
            case .io(let m):          return m
            }
        }
    }

    /// 레코드 하나를 옮긴다. 자리가 하나씩일 때의 줄임말이다.
    public static func move(_ fileName: String,
                            from source: SessionStore, to target: SessionStore) throws {
        try move(fileName, from: [source], to: [target])
    }
}

/// 넘기기 창이 보여줄 한 줄.
public struct SessionSummary: Sendable, Equatable, Identifiable {
    public let fileName: String
    public let cliSessionID: String
    public let title: String
    public let folder: String
    public let lastActivityAt: Date?
    /// 트랜스크립트가 없으면 옮겨도 빈 세션이 뜬다.
    public let hasTranscript: Bool
    /// 작업 폴더가 아직 있는지. worktree 를 지우면 없어진다.
    public let folderExists: Bool
    /// 이 대화를 두 계정 이상이 가리키고 있는지. 11절 규칙을 어긴 상태다.
    public let sharedRecord: Bool

    public var id: String { fileName }

    public init(fileName: String, cliSessionID: String, title: String, folder: String,
                lastActivityAt: Date?, hasTranscript: Bool, folderExists: Bool = true,
                sharedRecord: Bool = false) {
        self.fileName = fileName
        self.cliSessionID = cliSessionID
        self.title = title
        self.folder = folder
        self.lastActivityAt = lastActivityAt
        self.hasTranscript = hasTranscript
        self.folderExists = folderExists
        self.sharedRecord = sharedRecord
    }

    /// 제목을 못 읽었으면 폴더 이름으로 대신한다. 빈 줄을 보여주지 않는다.
    public var display: String { title.isEmpty ? folder : title }

    public static let noTranscript = "기록이 없어 옮겨도 빈 세션이 됩니다"
    public static let noFolder = "작업 폴더가 없어 그 자리에서 일할 수 없습니다"
    public static let sharedByAccounts = "두 계정에서 동시에 열려 있는 세션"

    /// 넘기기 전에 알아야 할 것. 없으면 `nil`.
    ///
    /// **막는 값이 아니라 보여주는 값이다.** 넘기기는 사용자가 명시적으로 하는
    /// 일이라 판단은 사용자 몫이고, 우리는 재료만 준다. 둘 다 걸리면 대화가
    /// 아예 없는 쪽을 말한다. 그게 더 큰 문제다.
    public var warning: String? {
        if !hasTranscript { return Self.noTranscript }
        // 겹침이 폴더 없음보다 앞이다. 겹친 쪽으로 넘기면 이름이 부딪혀 막힌다
        if sharedRecord { return Self.sharedByAccounts }
        if !folderExists { return Self.noFolder }
        return nil
    }

    /// 제목 아래 한 줄. 폴더 이름과 경고를 같이 적는다.
    ///
    /// **경고가 폴더를 밀어내지 않는다.** 폴더는 어느 워크트리에서 하던 일인지
    /// 말하고 경고는 지금 상태를 말한다. 다른 정보다.
    /// docs/design/handoff-list-mockup.html
    public var detail: String {
        [folder.isEmpty ? nil : folder, warning].compactMap { $0 }.joined(separator: " - ")
    }
}

extension SessionStore {
    /// 이 계정이 가진 세션. 제목은 트랜스크립트 양끝에서 읽는다.
    ///
    /// 폴더 확인은 주입받는다. 테스트가 진짜 디렉토리를 만들지 않아도 된다.
    public func summaries(projects: URL = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".claude/projects"),
                          folderExists: (String) -> Bool = {
                              FileManager.default.fileExists(atPath: $0)
                          },
                          sharedTranscripts: Set<String> = []) -> [SessionSummary] {
        let fm = FileManager.default
        return fileNames().compactMap { name -> SessionSummary? in
            guard let data = fm.contents(atPath: root.appendingPathComponent(name).path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cli = json["cliSessionId"] as? String
            else { return nil }

            let cwd = json["cwd"] as? String ?? json["originCwd"] as? String ?? ""
            let transcript = SessionMirror.transcriptPath(cli, projects: projects)
            return SessionSummary(
                fileName: name,
                cliSessionID: cli,
                title: transcript.map(TranscriptTitle.of) ?? "",
                folder: URL(fileURLWithPath: cwd).lastPathComponent,
                lastActivityAt: (json["lastActivityAt"] as? Double).map {
                    Date(timeIntervalSince1970: $0 / 1000)
                },
                hasTranscript: transcript != nil,
                // 경로를 모르면 없다고 하지 않는다. 지어낸 경고는 진짜 경고를 묻는다
                folderExists: cwd.isEmpty || folderExists(cwd),
                sharedRecord: sharedTranscripts.contains(cli))
        }
        .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
    }
}

extension SessionHandoff {
    /// 계정 하나의 레코드가 놓이는 자리 전부.
    ///
    /// 기본 데이터 디렉토리에 하나, 그 계정으로 띄운 별도 창이 있으면 거기에
    /// 하나 더 있다. 옮길 때 한 자리만 건드리면 남은 창이 그 세션을 계속
    /// 보여주므로, 자리를 다 모아서 한꺼번에 옮긴다.
    public static func stores(account uuid: String, name: String,
                              primary: URL, person: String,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [SessionStore] {
        var all = [SessionStore(dataDirectory: primary, person: person, account: uuid)]
        if let dir = AltInstance.directory(for: name, home: home),
           FileManager.default.fileExists(atPath: dir.path) {
            all.append(SessionStore(dataDirectory: dir, person: person, account: uuid))
        }
        return all
    }

    /// 자리를 다 옮긴다. 하나라도 막히면 아무것도 안 바꾼다.
    ///
    /// 지운 자리에는 **무덤을 남긴다.** 앱의 수동 "CLI 세션 가져오기" 는
    /// 트랜스크립트를 전수로 훑어 모르는 대화를 재수입하는데, 옮긴 대화는
    /// 옛 계정 인스턴스에게 모르는 대화라 무덤 없이는 가져오기 한 번에
    /// 좀비로 돌아온다. docs/design/15-move-janitor.html 4절
    public static func move(_ fileName: String,
                            from source: [SessionStore], to target: [SessionStore]) throws {
        let data = try place(fileName, from: source, into: target)
        let fm = FileManager.default
        let ids = Tombstones.ids(of: data)
        for store in source {
            try? fm.removeItem(at: store.root.appendingPathComponent(fileName))
            Tombstones.leave(ids, in: store)
        }
    }

    /// 양쪽에 둔다. **옮기기에서 삭제만 뺀 것이다.**
    ///
    /// 대화 본문은 계정 폴더 바깥에 하나뿐이라 레코드가 둘이어도 같은 파일을
    /// 가리킨다. 지우지 않는 것이 곧 공유다. docs/design/14-shared-session.md
    public static func share(_ fileName: String,
                             from source: [SessionStore], to target: [SessionStore]) throws {
        try place(fileName, from: source, into: target)
    }

    /// 옮기기와 공유가 같이 쓰는 몸통. 대상 자리에 다 넣는다.
    ///
    /// 먼저 넣고 지우는 것은 부르는 쪽이다. 중간에 죽어도 대화를 잃지 않는다.
    ///
    /// 넣으면서 대상의 **무덤을 걷는다.** 옛 무덤이 남아 있으면 방금 넣은
    /// 대화가 그 계정에서 지운 것으로 남는다.
    @discardableResult
    private static func place(_ fileName: String,
                              from source: [SessionStore], into target: [SessionStore])
        throws -> Data {
        let fm = FileManager.default
        guard let data = source.lazy
            .map({ $0.root.appendingPathComponent(fileName) })
            .first(where: { fm.fileExists(atPath: $0.path) })
            .flatMap({ fm.contents(atPath: $0.path) })
        else { throw Failure.missing(fileName) }

        guard !target.contains(where: { collides(fileName, in: $0.fileNames()) }) else {
            throw Failure.collision(fileName)
        }

        let ids = Tombstones.ids(of: data)
        for store in target {
            do {
                try fm.createDirectory(at: store.root, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                try data.write(to: store.root.appendingPathComponent(fileName))
            } catch {
                throw Failure.io("\(fileName) 을 넣지 못했다. \(error.localizedDescription)")
            }
            Tombstones.clear(ids, in: store)
        }
        return data
    }
}

/// 옮기기 전에 보여줄 안내. `HandoffAdvice` 의 반대쪽이다.
///
/// 저쪽은 옮긴 뒤 할 일을 말하고 이쪽은 옮기면 무슨 일이 생기는지 미리 말한다.
///
/// **보낸 쪽 창에 줄이 남는다는 것을 먼저 알려야 한다.** 목록에서 바로 빠질
/// 것처럼 말하면 거짓이다. 앱의 목록 갱신은 더하기만 해서 사라진 레코드를
/// 지우지 않는다. 남은 줄은 누르면 열리고 그러면 두 창이 같은 대화에 쓴다.
/// docs/design/13-multi-instance.md 12절
public struct HandoffPlan: Sendable, Equatable {
    public let moves: String
    /// 보낸 쪽에 남는 줄을 어떻게 하나. 할 말이 없으면 `nil`.
    public let sourceNote: String?
    /// 받는 쪽에 언제 나타나나. 할 말이 없으면 `nil`.
    public let targetNote: String?

    /// 화면에 뿌릴 줄들. 빈 것은 뺀다.
    public var lines: [String] { [moves, sourceNote, targetNote].compactMap { $0 } }

    public static func before(source: (name: String, slot: InstanceSlot),
                              target: (name: String, slot: InstanceSlot)) -> HandoffPlan {
        HandoffPlan(moves: "이 세션 작업을 \(target.name) 으로 이전합니다.",
                    sourceNote: leaving(source),
                    targetNote: arriving(target))
    }

    /// 보낸 쪽. 남은 줄은 청소부가 정리하므로 재시작을 시키지 않는다.
    ///
    /// 과장하면 안 된다. 옛 창의 화면 목록에는 줄이 남는다. 우리가 지우는
    /// 것은 디스크지 앱 메모리가 아니다. 마지막 문장은 청소부의 물러남
    /// 규칙을 사용자 말로 옮긴 것이다. docs/design/15-move-janitor.html 11절
    private static func leaving(_ a: (name: String, slot: InstanceSlot)) -> String? {
        switch a.slot {
        case .primary:
            return "\(a.name) 창 목록에는 재시작 전까지 남아 보일 수 있습니다. "
                + "남은 항목은 clf 가 정리하니 그대로 두면 됩니다. \n"
                + "옛 창에서 그 세션을 다시 열어 작업하면 이동이 취소된 것으로 봅니다."
        case .running:
            return "\(a.name) 창은 옮긴 뒤 다시 띄워 드립니다. 그러면 목록에서 빠집니다."
        case .opening, .none, .unavailable:
            return nil
        }
    }

    /// 받는 쪽. 이쪽은 나타나게 하려고 필요하다. 방향만 다르고 이유는 같다.
    private static func arriving(_ a: (name: String, slot: InstanceSlot)) -> String? {
        switch a.slot {
        case .primary: return "\(a.name) 기본 창도 재시작해야 목록에 나타납니다."
        case .running: return "\(a.name) 창은 다시 띄워 드립니다."
        case .opening, .none, .unavailable: return nil
        }
    }
}

/// 양쪽에 두고 나서 하는 말.
///
/// 옮기기와 달리 보낸 쪽이 아무것도 잃지 않아서 재시작 권고가 필요 없다.
/// 대신 **동시에 쓰면 안 된다는 것**을 여기서 한 번 말해 둔다. 공유의 전제라서
/// 모르고 쓰면 기록이 섞인다. docs/design/14-shared-session.md
public enum ShareNote {
    public static func after(shared: Int, target: (name: String, slot: InstanceSlot)) -> String {
        var say = "\(shared)개를 양쪽에 두었습니다. "
        switch target.slot {
        case .primary:  say += "\(target.name) 기본 창을 재시작하면 목록에 나타납니다. "
        case .running:  say += "\(target.name) 창은 아래 단추로 다시 띄워 주세요. "
        case .opening, .none, .unavailable: say += "\(target.name) 창을 띄우면 보입니다. "
        }
        return say + "두 창에서 같은 대화를 동시에 이어가지는 마세요."
    }

    public static func afterUnshare(_ count: Int, from name: String) -> String {
        "\(count)개의 공유를 끊었습니다. \(name) 목록에서는 재시작 뒤에 빠집니다."
    }
}

/// 옮긴 뒤에 남는 일.
///
/// 데스크톱 앱은 세션 목록을 메모리에 들고 있다. 레코드 파일만 바꾸면 화면은
/// 그대로다. 그래서 창마다 무엇을 해야 하는지 말해준다. 별도 창은 우리가
/// 띄운 것이라 다시 띄워 줄 수 있고, 기본 창은 사용자 것이라 말만 한다.
public struct HandoffAdvice: Sendable, Equatable {
    public let moved: Int
    /// 기본 앱을 재시작해야 반영된다.
    public let needsPrimaryRestart: Bool
    /// 우리가 다시 띄울 수 있는 별도 창.
    public let relaunch: [String]
    /// 창이 없어서 아무 일도 안 해도 되는 계정.
    public let dormant: [String]

    public static func after(moved: Int, source: (name: String, slot: InstanceSlot),
                             target: (name: String, slot: InstanceSlot)) -> HandoffAdvice {
        let both = [source, target]
        return HandoffAdvice(
            moved: moved,
            needsPrimaryRestart: both.contains { $0.slot == .primary },
            relaunch: both.filter { $0.slot == .running }.map(\.name),
            dormant: both.filter { $0.slot == .none || $0.slot == .opening }.map(\.name))
    }

    public var text: String { "\(moved)개를 옮겼습니다. " + detail }

    /// 옮겼다는 말 다음에 붙는 안내. 화면은 두 줄로 나눠 보여준다.
    public var detail: String {
        var parts: [String] = []
        if needsPrimaryRestart { parts.append("기본 앱을 재시작하면 목록에 반영됩니다.") }
        if !relaunch.isEmpty { parts.append("\(relaunch.joined(separator: ", ")) 창은 아래 단추로 다시 띄워 주세요.") }
        if parts.isEmpty { parts.append("창이 없으니 다음에 띄우면 보입니다.") }
        return parts.joined(separator: " ")
    }
}
