import Foundation
import ArgumentParser
import ClfCore
import ClfStore

/// 모든 하위 명령이 공유하는 경로 옵션.
///
/// 실제 데이터를 건드리지 않고 실험할 수 있어야 한다. 그래서 디렉토리 두 개를
/// 전부 밖에서 갈아끼울 수 있게 열어 둔다.
struct Paths: ParsableArguments {
    @Option(name: .customLong("data-dir"),
            help: "clf 데이터 디렉토리. 기본은 ~/Library/Application Support/clf")
    var dataDir: String?

    @Option(name: .customLong("claude-dir"),
            help: "Claude 설정 디렉토리. 기본은 CLAUDE_CONFIG_DIR 또는 ~/.claude")
    var claudeDir: String?

    /// 디렉토리만 갈아끼우면 격리가 반쪽이다. 자격증명은 여전히 진짜 Keychain 으로
    /// 간다. 실험용 서비스 이름을 주면 사용자의 항목과 완전히 갈린다.
    @Option(name: .customLong("keychain-service"),
            help: "Keychain 서비스 이름. 기본은 me.clf.credentials")
    var keychainService: String?

    var data: URL {
        get throws {
            if let dataDir { return URL(fileURLWithPath: expand(dataDir), isDirectory: true) }
            return try appSupportDirectory()
        }
    }
    var claude: URL {
        get throws {
            if let claudeDir { return URL(fileURLWithPath: expand(claudeDir), isDirectory: true) }
            return try ClaudeSettingsFile.defaultConfigDirectory()
        }
    }
    func settings() throws -> ClaudeSettingsFile {
        try ClaudeSettingsFile(configDirectory: claude, stateDirectory: data)
    }
    var credentials: KeychainCredentialStore {
        KeychainCredentialStore(service: keychainService ?? KeychainCredentialStore.service)
    }
    func accountsFile() throws -> AccountsFile { AccountsFile(directory: try data) }
    func runtimeFile() throws -> RuntimeFile { RuntimeFile(directory: try data) }

    private func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}

// MARK: 출력

/// ASCII 표. 박스 드로잉 문자를 쓰지 않는다.
func renderTable(_ header: [String], _ rows: [[String]]) -> String {
    guard !rows.isEmpty else { return "  (없음)" }
    let all = [header] + rows
    let widths = (0..<header.count).map { column in
        all.map { displayWidth($0[column]) }.max() ?? 0
    }
    func line(_ cells: [String]) -> String {
        "  " + zip(cells, widths).map { pad($0, to: $1) }
            .joined(separator: "  ").trimmingTrailing()
    }
    let rule = "  " + widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")
    return ([line(header), rule] + rows.map(line)).joined(separator: "\n")
}

/// 한글은 터미널에서 두 칸을 먹는다. 이걸 세지 않으면 표가 어긋난다.
func displayWidth(_ s: String) -> Int {
    s.unicodeScalars.reduce(0) { width, scalar in
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6:
            return width + 2
        default:
            return width + 1
        }
    }
}

func pad(_ s: String, to width: Int) -> String {
    s + String(repeating: " ", count: max(0, width - displayWidth(s)))
}

extension String {
    func trimmingTrailing() -> String {
        var s = self
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }
}

func percent(_ value: Double?) -> String {
    guard let value else { return "-" }
    return String(format: "%.0f%%", value * 100)
}

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    return f
}()

func stamp(_ date: Date?) -> String {
    guard let date else { return "-" }
    return timeFormatter.string(from: date)
}

/// 판정 결과를 종료 코드로 바꾼다. 스크립트가 이어붙일 수 있어야 한다.
struct CheckFailed: Error, CustomStringConvertible {
    let description: String
}
