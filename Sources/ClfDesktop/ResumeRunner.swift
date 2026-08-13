import Foundation

/// `claude` 실행 파일을 찾는다.
///
/// **PATH 는 안 본다.** Finder 나 로그인 항목으로 뜬 앱의 PATH 는
/// `/usr/bin:/bin:/usr/sbin:/sbin` 뿐이라 사용자가 설치한 자리가 들어 있지
/// 않다. 실제로 쓰이는 자리 셋을 직접 본다.
public enum ClaudeCLI {
    /// 찾아본 자리. 못 찾았을 때 화면에 이 목록을 그대로 보여준다.
    public static func candidates(
        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [home.appendingPathComponent(".local/bin/claude").path,
         "/opt/homebrew/bin/claude",
         "/usr/local/bin/claude"]
    }

    /// 실행할 수 있는 첫 번째 자리. 없으면 nil.
    public static func find(_ paths: [String] = candidates()) -> URL? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

/// 이어 돌린 결과.
public struct ResumeOutcome: Sendable, Equatable {
    public let exitCode: Int32
    /// stderr 첫 줄. 없으면 nil.
    public let detail: String?

    public init(exitCode: Int32, detail: String?) {
        self.exitCode = exitCode
        self.detail = detail
    }

    public var ok: Bool { exitCode == 0 }
}

/// 세션 하나를 이어 돌린다. **판정은 하지 않는다.**
///
/// 돌릴지 말지는 `AutoResumeWatch` 가 정한다. 여기는 정해진 것을 실행하고
/// 결과만 돌려준다. docs/design/16-auto-resume.md 4절
public struct ResumeRunner: Sendable {
    private let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// `claude --resume <ID> -p "<프롬프트>"`
    ///
    /// `-p` 라 창이 뜨지 않고 한 턴을 돌고 끝난다. 한 턴이 몇 분씩 가므로
    /// 기다리지 않고 종료 신호를 받는다.
    public func run(_ plan: AutoResumePlan) async throws -> ResumeOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--resume", plan.sessionID, "-p", plan.prompt]
        // 세션은 그 자리에서 돌아야 찾는다
        if !plan.cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: plan.cwd)
        }
        // 답변은 stdout 으로 길게 나온다. 우리가 읽을 것이 아니다
        process.standardOutput = FileHandle.nullDevice

        // 파이프가 아니라 파일로 받는다. 파이프 버퍼(64KB)가 차면 자식이 쓰다가
        // 멈추고 우리는 끝나기를 기다려서 서로 붙는다. 파일은 그 한계가 없다
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clf-resume-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let sink = try FileHandle(forWritingTo: log)
        process.standardError = sink

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                try? sink.close()
                let detail = Self.firstLine(of: log)
                try? FileManager.default.removeItem(at: log)
                continuation.resume(returning: ResumeOutcome(
                    exitCode: finished.terminationStatus, detail: detail))
            }
            do {
                try process.run()
            } catch {
                try? sink.close()
                try? FileManager.default.removeItem(at: log)
                continuation.resume(throwing: error)
            }
        }
    }

    /// 실패를 설명하는 한 줄. 길면 자른다. 로그 전문을 알림에 실을 수 없다.
    static func firstLine(of url: URL, limit: Int = 120) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        return line.count <= limit ? line : String(line.prefix(limit)) + "..."
    }
}
