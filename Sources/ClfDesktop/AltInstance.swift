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
    /// 이름에서 경로를 못 만들었다. 띄울 수 없다.
    case unavailable

    public var label: String {
        switch self {
        case .primary: return "기본"
        case .running: return "창 열려있음"
        case .opening: return "여는 중"
        case .none:    return "새 창 띄우기"
        case .unavailable: return "이름을 못 쓴다"
        }
    }

    /// 누를 수 있는 것은 하나뿐이다.
    public var isActionable: Bool { self == .none }

    /// 이름 옆에 붙는 상태 배지. HIG 는 단추 라벨을 동사로 쓰라고 하므로
    /// 상태는 배지로 가르고 단추에는 동작만 남긴다.
    ///
    /// `실행중` 이라고만 하면 세션이 돌고 있다는 말로 읽힌다. 여기서 말하는
    /// 것은 그 계정으로 띄운 **창이 떠 있다**는 것뿐이다.
    /// docs/design/popover-hig-mockup.html
    public var badgeLabel: String? { self == .running ? "창 열려있음" : nil }

    /// 누르면 일어나는 일. 동사다. 상태뿐인 자리는 nil 이다.
    ///
    /// 기본 창도 꺼낼 수 있다. 사용자가 원래 쓰던 창이라 오히려 제일 자주
    /// 찾는데, 여기만 단추가 없으면 팝오버에서 창으로 갈 길이 끊긴다.
    public var actionLabel: String? {
        switch self {
        case .none:              return "새 창 띄우기"
        case .running, .primary: return "앞으로 꺼내기"
        default:                 return nil
        }
    }

    public static func of(slug: String?, isPrimary: Bool,
                          running: Set<String>, opening: Set<String>) -> InstanceSlot {
        if isPrimary { return .primary }
        guard let slug else { return .unavailable }
        if running.contains(slug) { return .running }
        if opening.contains(slug) { return .opening }
        return .none
    }
}

/// 계정마다 데이터 디렉토리를 따로 둔 별도 인스턴스.
///
/// 데스크톱 앱은 Electron 의 `--user-data-dir` 스위치로 데이터 디렉토리를
/// 바꿀 수 있고 단일 인스턴스 잠금이 없다. 그래서 계정마다 하나씩 띄울 수 있다.
/// docs/design/13-multi-instance.md
public enum AltInstance {
    public static let executable =
        "/Applications/Claude.app/Contents/MacOS/Claude"
    /// 홈 아래 숨김 디렉토리. 이름에 계정 이름이 들어간다.
    public static let prefix = ".claude-alt-"

    /// 계정 이름을 경로 한 조각으로 만든다.
    ///
    /// **이름이 곧 경로다.** 여기가 구멍이 되면 홈 밖으로 나간다. 공백은 지우고
    /// 경로 구분자는 `-` 로 바꾸며, 앞의 점은 떼어낸다.
    public static func slug(_ name: String) -> String? {
        var s = name.components(separatedBy: .whitespacesAndNewlines).joined()
        for bad in ["/", "\\", ":"] { s = s.replacingOccurrences(of: bad, with: "-") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // 점과 대시만 남았으면 이름이 아니다. `../..` 가 `..` 로 남는다
        guard s.contains(where: { $0 != "." && $0 != "-" }), !s.contains("/") else { return nil }
        return s
    }

    public static func directory(for name: String,
                                 home: URL = FileManager.default
                                     .homeDirectoryForCurrentUser) -> URL? {
        guard let slug = slug(name) else { return nil }
        return home.appendingPathComponent(prefix + slug, isDirectory: true)
    }

    /// 우리가 만든 디렉토리인가. 지울 때 이걸로 거른다.
    public static func isOurs(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(prefix) && name.count > prefix.count
    }

    /// 계정마다 그 인스턴스의 pid. 창을 앞으로 꺼낼 때 쓴다.
    public static func scanInstances() -> [String: Int32] {
        runningInstances(psOutput: psOutput())
    }

    /// 지금 떠 있는 별도 인스턴스의 계정. 로컬 프로세스만 본다.
    public static func scanRunning() -> Set<String> {
        runningAccounts(psOutput: psOutput())
    }

    private static func psOutput() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -A 가 없으면 지금 터미널 세션의 프로세스만 나온다. 실제로 그래서 못 잡았다
        // -A 가 없으면 지금 터미널 세션의 프로세스만 나온다. 실제로 그래서 못 잡았다
        process.arguments = ["-A", "-E", "-o", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `ps` 출력에서 우리가 띄운 인스턴스의 계정을 골라낸다.
    ///
    /// `--user-data-dir` 스위치가 명령줄에 붙어 나온다. 기본 인스턴스에는 그
    /// 스위치가 없고, 헬퍼 프로세스는 실행 파일 경로가 다르다.
    public static func runningAccounts(psOutput: String) -> Set<String> {
        Set(slugAndPID(psOutput).map(\.slug))
    }

    /// 계정 이름과 그 인스턴스의 pid.
    public static func runningInstances(psOutput: String) -> [String: Int32] {
        Dictionary(slugAndPID(psOutput).compactMap { pair in
            pair.pid.map { (pair.slug, $0) }
        }, uniquingKeysWith: { a, _ in a })
    }

    private static func slugAndPID(_ psOutput: String) -> [(slug: String, pid: Int32?)] {
        psOutput.split(separator: "\n").compactMap { line in
            guard line.contains(executable),
                  !line.contains("Helper"),
                  let range = line.range(of: "--user-data-dir=")
            else { return nil }
            let path = line[range.upperBound...].prefix { !$0.isWhitespace }
            guard let name = path.split(separator: "/").last,
                  name.hasPrefix(prefix) else { return nil }
            let slug = String(name.dropFirst(prefix.count))
            guard !slug.isEmpty else { return nil }
            // `ps` 가 pid 를 앞에 붙여 준 경우에만 창을 꺼낼 수 있다
            let pid = line.split(separator: " ", maxSplits: 1).first.flatMap { Int32($0) }
            return (slug, pid)
        }
    }
}
