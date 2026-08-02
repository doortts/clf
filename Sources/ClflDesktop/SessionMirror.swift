import Foundation

/// 세션 레코드를 계정 사이로 옮긴다.
///
/// 레코드에는 대화 내용이 없다. `cliSessionId` 로 트랜스크립트를 가리키는
/// 포인터일 뿐이고, 트랜스크립트는 `~/.claude/projects` 에 있어 인스턴스끼리
/// 공유된다. 그래서 같은 대화를 계정마다 따로 가리킬 수 있다.
/// docs/design/13-multi-instance.md 4절
public enum SessionMirror {
    static let filePrefix = "local_"
    static let fileSuffix = ".json"

    /// 레코드 하나. 파일 이름과 그것이 가리키는 트랜스크립트.
    public struct Record: Sendable, Equatable {
        public let fileName: String
        public let transcriptID: String?
        public init(fileName: String, transcriptID: String?) {
            self.fileName = fileName
            self.transcriptID = transcriptID
        }
    }

    /// 무엇을 옮길지 정한다.
    ///
    /// **이미 있는 것은 안 건드린다.** 저쪽에서 고친 것을 덮으면 안 된다.
    /// 트랜스크립트가 없는 레코드도 뺀다. 옮겨 봐야 빈 세션이 뜨고 그건
    /// 고장으로 보인다.
    public static func plan(source: [Record], target: [String],
                            hasTranscript: (String) -> Bool) -> [String] {
        let have = Set(target)
        return source
            .filter { isOurs($0.fileName) && !have.contains($0.fileName) }
            .filter { $0.transcriptID.map(hasTranscript) ?? false }
            .map(\.fileName)
            .sorted()
    }

    static func isOurs(_ fileName: String) -> Bool {
        fileName.hasPrefix(filePrefix) && fileName.hasSuffix(fileSuffix)
            && fileName.count > filePrefix.count + fileSuffix.count
    }
}

/// 한 계정의 세션 레코드가 놓이는 자리.
///
/// `<데이터 디렉토리>/claude-code-sessions/<사람>/<계정>/local_*.json`
public struct SessionStore: Sendable {
    static let baseDir = "claude-code-sessions"

    public let root: URL
    public init(dataDirectory: URL, person: String, account: String) {
        self.root = dataDirectory
            .appendingPathComponent(Self.baseDir, isDirectory: true)
            .appendingPathComponent(person, isDirectory: true)
            .appendingPathComponent(account, isDirectory: true)
    }

    /// 이 데이터 디렉토리를 쓰는 사람. 계정 위 단계이고 하나뿐이다.
    public static func person(in dataDirectory: URL) -> String? {
        let base = dataDirectory.appendingPathComponent(baseDir, isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(atPath: base.path))?
            .first { !$0.hasPrefix(".") }
    }

    public func fileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter(SessionMirror.isOurs)
    }

    /// 파일 이름의 uuid 와 `cliSessionId` 는 다를 수 있다. 앱이 직접 만든
    /// 세션은 둘이 따로고, 딥링크로 가져온 것만 같다. 그래서 열어서 읽는다.
    public func records() -> [SessionMirror.Record] {
        fileNames().map { name in
            let data = FileManager.default.contents(atPath: root.appendingPathComponent(name).path)
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                as? [String: Any]
            return .init(fileName: name, transcriptID: json?["cliSessionId"] as? String)
        }
    }
}

extension SessionMirror {
    /// 트랜스크립트가 실제로 있는지 본다. 없으면 옮겨도 빈 세션이다.
    public static func transcriptExists(_ id: String,
                                        projects: URL = FileManager.default
                                            .homeDirectoryForCurrentUser
                                            .appendingPathComponent(".claude/projects")) -> Bool {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projects.path) else { return false }
        return dirs.contains { dir in
            fm.fileExists(atPath: projects.appendingPathComponent(dir)
                .appendingPathComponent("\(id).jsonl").path)
        }
    }

    /// 한쪽에만 있는 레코드를 다른 쪽으로 복사한다. 덮지 않는다.
    @discardableResult
    public static func sync(from source: SessionStore, to target: SessionStore) -> Int {
        let todo = plan(source: source.records(), target: target.fileNames(),
                        hasTranscript: { transcriptExists($0) })
        guard !todo.isEmpty else { return 0 }

        let fm = FileManager.default
        try? fm.createDirectory(at: target.root, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        var copied = 0
        for name in todo {
            let dst = target.root.appendingPathComponent(name)
            guard !fm.fileExists(atPath: dst.path),
                  (try? fm.copyItem(at: source.root.appendingPathComponent(name), to: dst)) != nil
            else { continue }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
            copied += 1
        }
        return copied
    }
}
