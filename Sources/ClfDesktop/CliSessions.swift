import Foundation

/// CLI 가 남긴 세션 하나.
///
/// **데스크톱 앱의 세션과 다른 것이다.** 이쪽은 `~/.claude/projects` 에 있는
/// CLI 기록이고, 작업 이전 탭이 다루는 것은 데스크톱 앱의 대화 레코드다.
/// 자동 재개는 CLI 로 돌리므로 CLI 가 아는 세션만 이어 돌릴 수 있다.
/// docs/design/16-auto-resume.md 6절
public struct CliSession: Sendable, Equatable, Identifiable {
    /// `claude --resume` 에 그대로 넘기는 값. 파일 이름에서 온다.
    public let id: String
    public let title: String
    /// 세션이 돌던 자리. 기록 안에 적혀 있다.
    public let cwd: String
    public let modifiedAt: Date

    public init(id: String, title: String, cwd: String, modifiedAt: Date) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.modifiedAt = modifiedAt
    }

    /// 목록 줄 아래에 적을 짧은 경로. 홈 아래면 `~` 로 줄인다.
    public func folder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        guard cwd.hasPrefix(home.path + "/") else { return cwd }
        return "~" + cwd.dropFirst(home.path.count)
    }
}

/// `~/.claude/projects/<프로젝트>/<세션ID>.jsonl` 을 훑는다.
///
/// **파일을 통째로 읽지 않는다.** 기록은 수십 MB 까지 자란다. 고를 후보는
/// mtime 으로 정하고, 고른 것의 앞부분만 읽어 제목과 작업 디렉토리를 얻는다.
public enum CliSessions {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// 제목을 못 찾았을 때. 없는 제목을 파일 이름으로 채우지 않는다.
    /// uuid 는 사람이 읽을 수 있는 이름이 아니다.
    public static let untitled = "제목 없는 세션"

    /// 제목과 작업 디렉토리를 찾으려고 읽는 앞부분. 둘 다 첫 열 줄 안에 있다.
    static let headBytes = 64 * 1024
    /// 그 안에서 살펴보는 줄 수. 못 찾으면 그만둔다.
    static let headLines = 60

    /// 최근에 손댄 것부터 `limit` 개.
    ///
    /// 더 오래된 세션을 자동으로 이어 돌릴 일은 드물다. 필요하면 그 세션을
    /// 한 번 열어 mtime 을 올리면 목록에 온다.
    public static func scan(root: URL = defaultRoot, limit: Int = 10) -> [CliSession] {
        let fm = FileManager.default
        let projects = (try? fm.contentsOfDirectory(at: root,
                                                    includingPropertiesForKeys: nil)) ?? []
        var found: [(url: URL, at: Date)] = []
        for project in projects {
            let files = (try? fm.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let at = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                found.append((file, at ?? .distantPast))
            }
        }
        return found
            .sorted { $0.at > $1.at }
            .prefix(limit)
            .map { describe($0.url, modifiedAt: $0.at) }
    }

    /// 기록 앞부분에서 제목과 작업 디렉토리를 읽는다.
    static func describe(_ url: URL, modifiedAt: Date) -> CliSession {
        var title: String?
        var fallback: String?
        var cwd: String?

        for line in head(url).prefix(headLines) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any] else { continue }
            if cwd == nil, let value = row["cwd"] as? String, !value.isEmpty { cwd = value }
            switch row["type"] as? String {
            case "custom-title":
                if let value = row["customTitle"] as? String, !value.isEmpty { title = value }
            case "user":
                // 사용자가 제목을 안 정한 세션. 첫 물음을 제목으로 쓴다
                if fallback == nil { fallback = firstAsk(row) }
            default:
                break
            }
            if title != nil, cwd != nil { break }
        }

        return CliSession(id: url.deletingPathExtension().lastPathComponent,
                          title: title ?? fallback ?? untitled,
                          cwd: cwd ?? "",
                          modifiedAt: modifiedAt)
    }

    /// 사용자 메시지에서 제목이 될 만한 한 줄.
    ///
    /// 본문에는 훅이 붙인 `<system-reminder>` 같은 것이 섞인다. 그것을 제목에
    /// 올리면 모든 세션의 제목이 같아진다.
    static func firstAsk(_ row: [String: Any]) -> String? {
        guard let message = row["message"] as? [String: Any] else { return nil }
        let text: String?
        switch message["content"] {
        case let value as String:
            text = value
        case let blocks as [[String: Any]]:
            text = blocks.compactMap { $0["text"] as? String }.first
        default:
            text = nil
        }
        guard var body = text else { return nil }
        if let cut = body.range(of: "<system-reminder") { body = String(body[body.startIndex..<cut.lowerBound]) }
        guard let line = body.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        return line.count <= 60 ? line : String(line.prefix(60)) + "..."
    }

    /// 파일 앞부분만 읽어 줄로 자른다.
    ///
    /// 자른 자리가 글자 가운데일 수 있다. 그 조각은 JSON 으로 안 읽혀서 그냥
    /// 버려지므로, 디코딩을 실패시키지 말고 대체 문자로 넘긴다. 실패로 두면
    /// 앞부분 전체가 사라진다.
    static func head(_ url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headBytes) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
