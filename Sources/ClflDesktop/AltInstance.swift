import Foundation

/// 계정 하나가 지금 어떤 창을 갖고 있는가.
public enum InstanceSlot: Sendable, Equatable, CaseIterable {
    /// 사용자가 원래 쓰던 인스턴스가 쓰는 계정.
    case primary
    /// 우리가 띄운 별도 인스턴스가 떠 있다.
    case running
    /// 띄우는 중. 245MB 를 푸느라 십수 초 걸린다.
    case opening
    /// 아무 창도 없다. 띄울 수 있다.
    case none

    public var label: String {
        switch self {
        case .primary: return "기본"
        case .running: return "창 실행중"
        case .opening: return "여는 중"
        case .none:    return "새 창 띄우기"
        }
    }

    /// 누를 수 있는 것은 하나뿐이다.
    public var isActionable: Bool { self == .none }

    public static func of(_ uuid: String, primary: String?,
                          running: Set<String>, opening: Set<String>) -> InstanceSlot {
        if uuid == primary { return .primary }
        if running.contains(uuid) { return .running }
        if opening.contains(uuid) { return .opening }
        return .none
    }
}

/// 계정마다 데이터 디렉토리를 따로 둔 별도 인스턴스.
///
/// 데스크톱 앱은 `CLAUDE_USER_DATA_DIR` 로 데이터 디렉토리를 바꿀 수 있고
/// 단일 인스턴스 잠금이 없다. 그래서 계정마다 하나씩 띄울 수 있다.
/// docs/design/13-multi-instance.md
public enum AltInstance {
    public static let executable =
        "/Applications/Claude.app/Contents/MacOS/Claude"
    /// 홈 아래 숨김 디렉토리. 이름에 계정 uuid 가 들어간다.
    public static let prefix = ".claude-alt-"

    /// **이름이 곧 경로다.** uuid 가 아닌 것을 받으면 홈 밖으로 나갈 수 있으므로
    /// 형식을 엄격히 본다.
    public static func directory(for uuid: String,
                                 home: URL = FileManager.default
                                     .homeDirectoryForCurrentUser) -> URL? {
        guard isUUID(uuid) else { return nil }
        return home.appendingPathComponent(prefix + uuid.lowercased(), isDirectory: true)
    }

    static func isUUID(_ s: String) -> Bool {
        s.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
                options: .regularExpression) != nil
    }

    /// 지금 떠 있는 별도 인스턴스의 계정. 로컬 프로세스만 본다.
    public static func scanRunning() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -A 가 없으면 지금 터미널 세션의 프로세스만 나온다. 실제로 그래서 못 잡았다
        process.arguments = ["-A", "-E", "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return runningAccounts(psOutput: String(decoding: data, as: UTF8.self))
    }

    /// `ps -E` 출력에서 우리가 띄운 인스턴스의 계정을 골라낸다.
    ///
    /// 환경변수가 명령줄 뒤에 붙어 나온다. 기본 인스턴스에는 그 변수가 없고,
    /// 헬퍼 프로세스는 실행 파일 경로가 다르다.
    public static func runningAccounts(psOutput: String) -> Set<String> {
        var found: Set<String> = []
        for line in psOutput.split(separator: "\n") {
            guard line.contains(executable),
                  !line.contains("Helper"),
                  let range = line.range(of: "CLAUDE_USER_DATA_DIR=")
            else { continue }
            let path = line[range.upperBound...].prefix { !$0.isWhitespace }
            guard let name = path.split(separator: "/").last,
                  name.hasPrefix(prefix) else { continue }
            let uuid = String(name.dropFirst(prefix.count))
            if isUUID(uuid) { found.insert(uuid.lowercased()) }
        }
        return found
    }
}
