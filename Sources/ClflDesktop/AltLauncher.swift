import CommonCrypto
import Foundation
import SQLite3

/// 씨앗을 심고 인스턴스를 띄운다.
///
/// **여기가 유일하게 데스크톱 앱의 파일을 쓰는 자리다.** 다만 쓰는 곳은
/// 우리가 만든 디렉토리(`~/.claude-alt-<계정>`)이고, 사용자가 원래 쓰던
/// `~/Library/Application Support/Claude` 는 읽기만 한다.
/// docs/design/13-multi-instance.md 7절
public struct AltLauncher: Sendable {
    /// 로그인을 물려주는 데 필요한 것 전부. 44K 면 된다.
    static let seedFiles = ["config.json", "Local State", "Preferences"]

    private let source: URL
    public init(source: URL = DesktopReader.defaultSupportDirectory) {
        self.source = source
    }

    /// 계정 하나짜리 인스턴스를 띄운다. 이미 씨앗이 있으면 다시 심지 않는다.
    ///
    /// 디렉토리 이름은 계정 이름에서, 로그인 계정은 uuid 로 정한다.
    ///
    /// `mirrorFrom` 을 주면 그 계정의 세션 목록을 새 인스턴스에도 심는다.
    /// 레코드는 포인터일 뿐이고 트랜스크립트는 공유되므로 같은 대화가 새
    /// 계정에서 열린다.
    @discardableResult
    public func launch(name: String, uuid: String, mirrorFrom sourceOrg: String? = nil)
    throws -> URL {
        let dir = try seed(name: name, uuid: uuid)
        if let sourceOrg { mirrorIn(dir: dir, targetOrg: uuid, sourceOrg: sourceOrg) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: AltInstance.executable)
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_USER_DATA_DIR"] = dir.path
        process.environment = env
        // 우리가 죽어도 창은 남아야 한다. 기다리지 않는다
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return dir
    }

    /// 데이터 디렉토리를 만들고 로그인을 물려준다.
    public func seed(name: String, uuid: String) throws -> URL {
        guard let dir = AltInstance.directory(for: name) else {
            throw SafeStorageError(description: "계정 이름으로 디렉토리를 못 만든다")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        let cookies = dir.appendingPathComponent("Cookies")
        if !fm.fileExists(atPath: cookies.path) {
            // 앱이 열고 있는 파일이다. 그냥 복사하면 찢어진 상태를 받을 수 있어
            // SQLite 백업 API 로 일관된 사본을 뜬다
            try backupSQLite(from: source.appendingPathComponent("Cookies"), to: cookies)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cookies.path)
        }
        for name in Self.seedFiles {
            let dst = dir.appendingPathComponent(name)
            let src = source.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            try fm.copyItem(at: src, to: dst)
        }

        // 띄우기 전에 계정을 박아 둔다. 그래야 로그인 화면 없이 그 계정으로 뜬다
        try setActiveAccount(uuid, in: cookies)
        return dir
    }

    /// 우리가 만든 디렉토리를 전부 지운다. 떠 있는 창의 것은 남긴다.
    ///
    /// 지우는 대상을 이름으로 거른다. `.claude-alt-` 로 시작하지 않으면
    /// 우리 것이 아니므로 손대지 않는다.
    @discardableResult
    public func removeAll(keeping running: Set<String>,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> (removed: Int, keptRunning: Int, freedBytes: Int64) {
        let fm = FileManager.default
        // 숨김 디렉토리를 찾는 것이 목적이므로 걸러내지 않는다
        let all = (try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        var removed = 0, kept = 0, freed: Int64 = 0
        for url in all where AltInstance.isOurs(url) {
            let slug = String(url.lastPathComponent.dropFirst(AltInstance.prefix.count))
            if running.contains(slug) { kept += 1; continue }
            freed += Int64(directorySize(url))
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return (removed, kept, freed)
    }

    func directorySize(_ url: URL) -> Int {
        var total = 0
        let walker = FileManager.default.enumerator(at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        while let f = walker?.nextObject() as? URL {
            total += (try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                .totalFileAllocatedSize) as? Int ?? 0
        }
        return total
    }

    // MARK: 안쪽

    private func setActiveAccount(_ uuid: String, in cookies: URL) throws {
        let key = try safeStorageKeyFromKeychain()
        // 쿠키 평문은 SHA256(host_key) 32바이트가 앞에 붙는다
        let blob = try encryptV10(domainHash(".claude.ai") + Data(uuid.utf8), key: key)
        try writeCookieBlob(blob, to: cookies, name: "lastActiveOrg")
    }

    private func backupSQLite(from src: URL, to dst: URL) throws {
        var from: OpaquePointer?, to: OpaquePointer?
        guard sqlite3_open_v2(src.path, &from, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw SafeStorageError(description: "쿠키 원본을 열지 못했다")
        }
        defer { sqlite3_close(from) }
        guard sqlite3_open_v2(dst.path, &to,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw SafeStorageError(description: "쿠키 사본을 만들지 못했다")
        }
        defer { sqlite3_close(to) }
        guard let backup = sqlite3_backup_init(to, "main", from, "main") else {
            throw SafeStorageError(description: "쿠키 백업을 시작하지 못했다")
        }
        sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard sqlite3_errcode(to) == SQLITE_OK else {
            throw SafeStorageError(description: "쿠키 백업 실패")
        }
    }
}

/// 쿠키 평문 앞에 붙는 32바이트. `stripDomainHash` 가 읽을 때 떼는 그것이다.
func domainHash(_ host: String) -> Data {
    var out = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
    let input = Data(host.utf8)
    out.withUnsafeMutableBytes { o in
        input.withUnsafeBytes { i in
            _ = CC_SHA256(i.baseAddress, CC_LONG(input.count),
                          o.bindMemory(to: UInt8.self).baseAddress)
        }
    }
    return out
}

func writeCookieBlob(_ blob: Data, to url: URL, name: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        throw SafeStorageError(description: "쿠키를 쓰려고 열지 못했다")
    }
    defer { sqlite3_close(db) }

    var statement: OpaquePointer?
    let sql = "update cookies set encrypted_value = ? where host_key = ? and name = ?"
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw SafeStorageError(description: "쿠키 갱신을 준비하지 못했다")
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(blob.count),
                                                 transient) }
    sqlite3_bind_text(statement, 2, ".claude.ai", -1, transient)
    sqlite3_bind_text(statement, 3, name, -1, transient)
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw SafeStorageError(description: "\(name) 쿠키를 쓰지 못했다")
    }
    guard sqlite3_changes(db) > 0 else {
        throw SafeStorageError(description: "\(name) 쿠키가 없어 못 바꿨다. 먼저 로그인해야 한다")
    }
}

/// 지우기 전에 무엇이 사라지는지 담아 둔다.
///
/// 되돌릴 수 없는 일이므로 먼저 보여주고 확인을 받는다.
public struct PurgePlan: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        public let isRunning: Bool
        public init(name: String, bytes: Int64, isRunning: Bool) {
            self.name = name; self.bytes = bytes; self.isRunning = isRunning
        }
    }

    public let entries: [Entry]
    public init(entries: [Entry]) { self.entries = entries }

    /// 떠 있는 창의 것은 안 지운다. 쓰는 중에 지우면 그 인스턴스가 깨진다.
    public var deletable: [Entry] { entries.filter { !$0.isRunning } }
    public var keptRunning: [Entry] { entries.filter(\.isRunning) }
    public var freedBytes: Int64 { deletable.reduce(0) { $0 + $1.bytes } }
    public var isEmpty: Bool { deletable.isEmpty }

    /// 몇 개인지가 아니라 무엇인지 말한다. 이름을 봐야 판단할 수 있다.
    public var summary: String {
        var out = deletable.map { "\($0.name) (\(Self.size($0.bytes)))" }
            .joined(separator: ", ")
        if !keptRunning.isEmpty {
            out += "\n창이 떠 있는 " + keptRunning.map(\.name).joined(separator: ", ")
                + " 는 남긴다"
        }
        return out
    }

    /// 무엇을 잃는지. 이게 없으면 사용자가 판단할 수 없다.
    public var consequence: String {
        "그 계정 창의 대화 목록이 사라진다. 대화 내용 자체는 남고 다시 띄우면 로그인도 유지된다"
    }

    public static func size(_ bytes: Int64) -> String {
        "\(max(0, Int((Double(bytes) / 1024 / 1024).rounded())))MB"
    }
}

extension AltLauncher {
    /// 무엇이 지워질지 미리 센다. 아무것도 건드리지 않는다.
    public func plan(running: Set<String>,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> PurgePlan {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        let entries = all.filter(AltInstance.isOurs).map { url -> PurgePlan.Entry in
            let name = String(url.lastPathComponent.dropFirst(AltInstance.prefix.count))
            return .init(name: name, bytes: Int64(directorySize(url)),
                         isRunning: running.contains(name))
        }
        return PurgePlan(entries: entries.sorted { $0.name < $1.name })
    }
}

extension AltLauncher {
    /// 기본 인스턴스에서 보던 세션을 새 인스턴스에도 심는다.
    func mirrorIn(dir: URL, targetOrg: String, sourceOrg: String) {
        guard let person = SessionStore.person(in: source) else { return }
        SessionMirror.sync(
            from: SessionStore(dataDirectory: source, person: person, account: sourceOrg),
            to: SessionStore(dataDirectory: dir, person: person, account: targetOrg))
    }

    /// 별도 창에서 한 작업을 기본 인스턴스에도 보이게 한다.
    ///
    /// **여기가 사용자의 기본 데이터 디렉토리에 쓰는 유일한 자리다.** 같은
    /// 계정 폴더에 레코드만 더한다. 기존 파일은 덮지 않고, 기본 창에서 그
    /// 계정으로 바꾸면 그때 목록에 나타난다.
    @discardableResult
    public func mirrorBack(account uuid: String, name: String) -> Int {
        guard let dir = AltInstance.directory(for: name),
              FileManager.default.fileExists(atPath: dir.path),
              let person = SessionStore.person(in: source)
        else { return 0 }
        return SessionMirror.sync(
            from: SessionStore(dataDirectory: dir, person: person, account: uuid),
            to: SessionStore(dataDirectory: source, person: person, account: uuid))
    }
}
