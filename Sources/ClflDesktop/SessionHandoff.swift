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

    /// 레코드 하나를 옮긴다. 원자적으로 옮기고 실패하면 아무것도 안 바꾼다.
    public static func move(_ fileName: String,
                            from source: SessionStore, to target: SessionStore) throws {
        let fm = FileManager.default
        let src = source.root.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: src.path) else { throw Failure.missing(fileName) }
        guard !collides(fileName, in: target.fileNames()) else {
            throw Failure.collision(fileName)
        }
        do {
            try fm.createDirectory(at: target.root, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.moveItem(at: src, to: target.root.appendingPathComponent(fileName))
        } catch {
            throw Failure.io("\(fileName) 을 옮기지 못했다. \(error.localizedDescription)")
        }
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

    public var id: String { fileName }

    public init(fileName: String, cliSessionID: String, title: String, folder: String,
                lastActivityAt: Date?, hasTranscript: Bool) {
        self.fileName = fileName
        self.cliSessionID = cliSessionID
        self.title = title
        self.folder = folder
        self.lastActivityAt = lastActivityAt
        self.hasTranscript = hasTranscript
    }

    /// 제목을 못 읽었으면 폴더 이름으로 대신한다. 빈 줄을 보여주지 않는다.
    public var display: String { title.isEmpty ? folder : title }
}

extension SessionStore {
    /// 이 계정이 가진 세션. 제목은 트랜스크립트 양끝에서 읽는다.
    public func summaries(projects: URL = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".claude/projects")) -> [SessionSummary] {
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
                hasTranscript: transcript != nil)
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
    public static func move(_ fileName: String,
                            from source: [SessionStore], to target: [SessionStore]) throws {
        let fm = FileManager.default
        guard let data = source.lazy
            .map({ $0.root.appendingPathComponent(fileName) })
            .first(where: { fm.fileExists(atPath: $0.path) })
            .flatMap({ fm.contents(atPath: $0.path) })
        else { throw Failure.missing(fileName) }

        if let hit = target.first(where: { collides(fileName, in: $0.fileNames()) }) {
            _ = hit
            throw Failure.collision(fileName)
        }

        // 먼저 넣고 나중에 지운다. 중간에 죽어도 대화를 잃지 않는다
        for store in target {
            do {
                try fm.createDirectory(at: store.root, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                try data.write(to: store.root.appendingPathComponent(fileName))
            } catch {
                throw Failure.io("\(fileName) 을 넣지 못했다. \(error.localizedDescription)")
            }
        }
        for store in source {
            try? fm.removeItem(at: store.root.appendingPathComponent(fileName))
        }
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

    public var text: String {
        var parts = ["\(moved)개를 옮겼다."]
        if needsPrimaryRestart { parts.append("기본 앱을 재시작해야 목록에 반영된다.") }
        if !relaunch.isEmpty { parts.append("\(relaunch.joined(separator: ", ")) 창은 다시 띄워야 한다.") }
        if relaunch.isEmpty && !needsPrimaryRestart {
            parts.append("창이 없으니 다음에 띄우면 보인다.")
        }
        return parts.joined(separator: " ")
    }
}
