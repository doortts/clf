import Foundation

/// `security` CLI 호출 한 겹.
///
/// Security framework 대신 CLI 를 쓰는 이유는 개발 빌드마다 코드서명이 바뀌면
/// Keychain ACL 이 매번 깨져 프롬프트가 반복되기 때문이다.
/// docs/design/07-oauth-credentials.md 3절
enum SecurityCLI {
    static let path = "/usr/bin/security"
    /// 항목을 못 찾았을 때의 종료 코드. 오류가 아니라 부재로 다룬다.
    static let itemNotFound: Int32 = 44

    struct Result {
        var status: Int32
        var stdout: Data
        var stderr: String
    }

    static func run(_ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            throw StoreError.keychainFailed(reason: "security 를 실행하지 못했다: \(error)")
        }

        // 읽기 전에 기다리면 파이프 버퍼가 차서 교착한다. 자격증명은 작지만
        // 규칙으로 지킨다.
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(status: process.terminationStatus, stdout: stdout,
                      stderr: String(decoding: stderr, as: UTF8.self)
                          .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// stdout 끝의 개행 하나를 떼고 문자열로 준다. 항목이 없으면 nil.
    static func findPassword(service: String, account: String) throws -> String? {
        let result = try run(["find-generic-password", "-s", service, "-a", account, "-w"])
        if result.status == itemNotFound { return nil }
        guard result.status == 0 else {
            throw StoreError.keychainFailed(reason: result.stderr)
        }
        var text = String(decoding: result.stdout, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
