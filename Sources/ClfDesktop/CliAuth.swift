import Foundation

/// CLI 가 어느 계정으로 로그인돼 있나.
///
/// **자동 재개의 전제다.** 우리가 고르는 계정은 한도를 지켜볼 계정이고, 실제
/// 실행은 CLI 가 자기 로그인 계정으로 한다. 둘이 다르면 엉뚱한 계정의 리셋에
/// 맞춰 남의 한도를 쓴다. 로그인이 아예 없으면 예약은 걸리는데 실행은 매번
/// 실패한다. docs/design/16-auto-resume.md 5절
public enum CliAuthStatus: Sendable, Equatable {
    /// 물어보는 중.
    case checking
    /// 물어보지 못했다. 실행이 실패했거나 답이 우리가 아는 꼴이 아니다.
    case unreadable(String)
    case loggedOut
    case loggedIn(orgID: String, orgName: String)

    /// 창 아래에 적을 한 줄.
    ///
    /// `watching` 은 지금 고른 지켜볼 계정이다. 이름을 모르면 uuid 만 있다.
    /// **일치할 때도 말한다.** 조용히 있으면 확인을 한 것인지 못 한 것인지
    /// 구분이 안 된다.
    public func line(watching uuid: String, named name: String?) -> CliAuthLine {
        switch self {
        case .checking:
            return CliAuthLine(text: "CLI 로그인 계정을 확인하는 중입니다", accent: .none)
        case .unreadable(let why):
            return CliAuthLine(text: "CLI 로그인 계정을 확인하지 못했습니다. \(why)",
                               accent: .wait)
        case .loggedOut:
            return CliAuthLine(
                text: "CLI 가 로그인돼 있지 않습니다. 터미널에서 claude auth login 을 먼저 하세요",
                accent: .bad)
        case .loggedIn(let orgID, let orgName):
            guard !uuid.isEmpty else {
                return CliAuthLine(text: "CLI 로그인: \(orgName)", accent: .good)
            }
            guard orgID != uuid else {
                return CliAuthLine(text: "CLI 로그인: \(orgName). 지켜볼 계정과 같습니다",
                                   accent: .good)
            }
            // 돌기는 도는데 다른 계정의 한도를 쓴다. 실패가 아니라서 알아채기
            // 어렵고, 그래서 더 크게 적는다
            let watched = name ?? uuid
            return CliAuthLine(
                text: "CLI 로그인: \(orgName). 지켜볼 계정 \(watched) 와 달라서"
                    + " \(orgName) 의 한도로 돕니다",
                accent: .bad)
        }
    }
}

/// 그 한 줄과 색. 색 어휘는 상태 상자와 같은 것을 쓴다.
public struct CliAuthLine: Sendable, Equatable {
    public let text: String
    public let accent: AutoResumeStatus.Accent

    public init(text: String, accent: AutoResumeStatus.Accent) {
        self.text = text
        self.accent = accent
    }
}

/// `claude auth status --json` 을 물어본다.
///
/// 자격증명 파일을 직접 읽지 않는다. 형식이 바뀌면 조용히 틀린 답을 하게 되고,
/// 무엇보다 우리가 읽을 이유가 없는 것을 읽게 된다. CLI 가 자기 상태를 답하는
/// 문이 이미 있으므로 그것만 쓴다.
public struct CliAuthReader: Sendable {
    private let executable: URL
    /// 이만큼 안 끝나면 그만둔다. 창을 열 때마다 도는 일이라 매달릴 수 없다.
    public static let timeout: TimeInterval = 10

    public init(executable: URL) {
        self.executable = executable
    }

    public func check() async -> CliAuthStatus {
        do {
            let (code, out) = try await run()
            guard code == 0 else {
                return .unreadable("claude 가 exit \(code) 로 끝났습니다")
            }
            return Self.parse(out)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// 답을 읽는다. 앞뒤에 다른 줄이 섞여도 첫 JSON 객체만 본다.
    static func parse(_ text: String) -> CliAuthStatus {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end,
              let root = try? JSONSerialization.jsonObject(
                with: Data(text[start...end].utf8)) as? [String: Any]
        else { return .unreadable("답을 알아볼 수 없습니다") }

        guard root["loggedIn"] as? Bool == true else { return .loggedOut }
        guard let orgID = root["orgId"] as? String, !orgID.isEmpty else {
            // 로그인은 됐는데 조직을 모른다. API 키로 붙은 경우가 여기다.
            // 계정을 대조할 수 없으니 모른다고 말한다
            return .unreadable("로그인은 돼 있는데 계정을 알려주지 않았습니다")
        }
        return .loggedIn(orgID: orgID,
                         orgName: root["orgName"] as? String
                            ?? root["email"] as? String ?? orgID)
    }

    /// 실행하고 stdout 을 받는다.
    ///
    /// stdout 을 파일로 받는 이유는 `ResumeRunner` 가 stderr 에 그러는 것과
    /// 같다. 파이프 버퍼가 차면 자식이 쓰다 멈추고 서로 붙는다.
    private func run() async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "status", "--json"]
        process.standardError = FileHandle.nullDevice

        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clf-auth-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let sink = try FileHandle(forWritingTo: log)
        process.standardOutput = sink

        let outcome: (Int32, String) = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                try? sink.close()
                let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: log)
                continuation.resume(returning: (finished.terminationStatus, text))
            }
            do {
                try process.run()
            } catch {
                try? sink.close()
                try? FileManager.default.removeItem(at: log)
                continuation.resume(throwing: error)
            }
            // 매달려 있으면 끊는다. 끊긴 프로세스는 0 이 아닌 코드로 끝나므로
            // 위의 종료 처리가 그대로 답을 만든다
            Task {
                try? await Task.sleep(for: .seconds(Self.timeout))
                if process.isRunning { process.terminate() }
            }
        }
        return outcome
    }
}
