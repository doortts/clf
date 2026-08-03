import Foundation

/// 임시 파일 + rename 으로 원자적 교체. 모드 0600.
/// docs/design/02-domain-model.md 6절
///
/// rename(2) 은 같은 파일시스템 안에서 원자적이라 임시 파일을 목적지와 같은
/// 디렉토리에 만든다. /tmp 에 만들고 옮기면 파일시스템이 갈려 원자성이 깨진다.
public func atomicWrite(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])

    let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")

    guard FileManager.default.createFile(
        atPath: tmp.path, contents: data,
        attributes: [.posixPermissions: 0o600])
    else {
        throw StoreError.writeFailed(url, reason: "임시 파일을 만들지 못했다")
    }

    // 실패하면 임시 파일이 남지 않게 한다. 성공 경로에서는 rename 이 가져간다.
    var renamed = false
    defer { if !renamed { try? FileManager.default.removeItem(at: tmp) } }

    let ok = tmp.withUnsafeFileSystemRepresentation { from in
        url.withUnsafeFileSystemRepresentation { to in
            guard let from, let to else { return false }
            return rename(from, to) == 0
        }
    }
    guard ok else {
        throw StoreError.writeFailed(url, reason: String(cString: strerror(errno)))
    }
    renamed = true
}

/// 앱 데이터 디렉토리. ~/Library/Application Support/clf/
public func appSupportDirectory() throws -> URL {
    let base = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
    let directory = base.appendingPathComponent("clf", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    return directory
}

public enum StoreError: Error, Sendable, Equatable {
    case writeFailed(URL, reason: String)
    case corruptFile(URL)
    /// settings.json 에 우리 것이 아닌 값이 이미 있다. force 로만 넘어간다.
    case settingsConflict(key: String, existing: String)
    case keychainFailed(reason: String)
    case credentialMissing(String)
}

// MARK: JSON 공통

/// 사람이 열어보고 손으로 고칠 수 있는 파일을 만든다. 키 정렬은 diff 안정성 때문.
func makeEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return e
}

func makeDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}
