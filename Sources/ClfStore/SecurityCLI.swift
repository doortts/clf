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
        return decodeSecurityOutput(text)
    }
}

/// `security` 는 값에 출력 불가 바이트가 하나라도 있으면 원문 대신 소문자
/// 16진수를 낸다. 그것을 그대로 파싱하면 형식을 알 수 없다며 죽는다.
///
/// 우리 형식은 `L:` 이나 `O:` 로 시작하고 Claude CLI 슬롯은 `{` 로 시작한다.
/// 셋 다 소문자 16진수 집합 밖이라 hex 출력과 겹칠 수 없다. 그래서 판정이 결정적이다.
func decodeSecurityOutput(_ text: String) -> String {
    guard !text.isEmpty, text.count % 2 == 0,
          text.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    else { return text }

    var bytes: [UInt8] = []
    bytes.reserveCapacity(text.count / 2)
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else { return text }
        bytes.append(byte)
        index = next
    }
    return String(decoding: bytes, as: UTF8.self)
}
