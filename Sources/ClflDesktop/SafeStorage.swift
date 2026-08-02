import CommonCrypto
import Foundation

/// Chromium safe storage. Claude 데스크톱 앱이 쿠키와 토큰 캐시를 이걸로 감싼다.
///
/// ```
/// 키   = PBKDF2-SHA1(Keychain["Claude Safe Storage"], "saltysalt", 1003회, 16바이트)
/// IV   = 0x20 * 16
/// 값   = "v10" + AES-128-CBC(평문 + PKCS7)
/// ```
/// docs/design/10-desktop-usage.md 2절
public enum SafeStorage {
    public static let keychainService = "Claude Safe Storage"
    static let salt = Data("saltysalt".utf8)
    static let rounds: UInt32 = 1003
    static let keyLength = 16
    static let iv = Data(repeating: 0x20, count: 16)
    static let versionPrefix = Data("v10".utf8)
}

public struct SafeStorageError: Error, CustomStringConvertible {
    public let description: String
}

/// Keychain 의 비밀번호에서 AES 키를 뽑는다.
public func safeStorageKey(password: String) throws -> Data {
    var key = Data(count: SafeStorage.keyLength)
    let status = key.withUnsafeMutableBytes { out -> Int32 in
        SafeStorage.salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, SafeStorage.salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), SafeStorage.rounds,
                out.bindMemory(to: UInt8.self).baseAddress, SafeStorage.keyLength)
        }
    }
    guard status == kCCSuccess else {
        throw SafeStorageError(description: "PBKDF2 실패: \(status)")
    }
    return key
}

/// 한 번 읽은 키를 들고 있는다.
///
/// 계정 감시가 5초마다 도는데 그때마다 `security` 프로세스를 띄우면 하루에
/// 만 칠천 번이다. 키는 앱이 도는 동안 안 바뀐다.
private final class KeyCache: @unchecked Sendable {
    static let shared = KeyCache()
    private let lock = NSLock()
    private var key: Data?

    func get(_ make: () throws -> Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let key { return key }
        let fresh = try make()
        key = fresh
        return fresh
    }
}

/// `security` CLI 로 읽는다. Security framework 를 쓰면 개발 빌드마다 코드서명이
/// 바뀌어 프롬프트가 반복된다. docs/design/07-oauth-credentials.md 3절
public func safeStorageKeyFromKeychain() throws -> Data {
    try KeyCache.shared.get(readSafeStorageKey)
}

private func readSafeStorageKey() throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", SafeStorage.keychainService, "-w"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let password = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !password.isEmpty else {
        throw SafeStorageError(description:
            "Keychain 의 '\(SafeStorage.keychainService)' 를 읽지 못했다")
    }
    return try safeStorageKey(password: password)
}

/// 접두사가 없으면 암호문이 아니다. 그대로 돌려준다.
public func decryptV10(_ blob: Data, key: Data) throws -> Data {
    guard blob.count > 3, blob.prefix(3) == SafeStorage.versionPrefix else { return blob }
    return try crypt(operation: kCCDecrypt, input: blob.dropFirst(3), key: key)
}

public func encryptV10(_ plain: Data, key: Data) throws -> Data {
    SafeStorage.versionPrefix + (try crypt(operation: kCCEncrypt, input: plain, key: key))
}

/// 쿠키 평문은 `SHA256(host_key)` 32바이트가 앞에 붙는다. 토큰 캐시는 안 붙는다.
/// 짧으면 접두사가 없는 것이므로 손대지 않는다.
public func stripDomainHash(_ plain: Data) -> Data {
    plain.count > 32 ? Data(plain.dropFirst(32)) : plain
}

private func crypt(operation: Int, input: Data, key: Data) throws -> Data {
    let capacity = input.count + kCCBlockSizeAES128
    var out = Data(count: capacity)
    var moved = 0
    let status = out.withUnsafeMutableBytes { outBytes in
        input.withUnsafeBytes { inBytes in
            key.withUnsafeBytes { keyBytes in
                SafeStorage.iv.withUnsafeBytes { ivBytes in
                    CCCrypt(CCOperation(operation), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inBytes.baseAddress, input.count,
                            outBytes.baseAddress, capacity, &moved)
                }
            }
        }
    }
    guard status == kCCSuccess else {
        throw SafeStorageError(description: "AES 실패: \(status)")
    }
    return out.prefix(moved)
}
