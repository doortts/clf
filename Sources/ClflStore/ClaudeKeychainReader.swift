import Foundation

/// Claude CLI 가 소유한 자격증명 슬롯을 **읽기만** 한다.
///
/// CCSwitcher 는 이 슬롯을 덮어써서 전환하지만 clfl 은 캡처 시점에 한 번 읽을 뿐
/// 절대 쓰지 않는다. 라우팅은 프록시가 헤더로 하므로 남의 자격증명 자리를 바꿀
/// 이유가 없다. docs/design/07-oauth-credentials.md 3절
///
/// 그 결과 조직 여러 개를 캡처하면 이 슬롯에는 마지막에 로그인한 것이 남는다.
/// 프록시를 우회하는 `claude` CLI 직접 호출만 그 조직으로 간다.
public struct ClaudeKeychainReader: Sendable {
    public static let service = "Claude Code-credentials"

    public init() {}

    /// 슬롯의 원문 JSON. 없으면 nil.
    ///
    /// 계정 이름이 OS 사용자명이라는 것은 CCSwitcher 관측 기준이며 확인이 필요하다.
    /// docs/design/07-oauth-credentials.md 10절
    public func readRawCredential(osUsername: String = NSUserName()) throws -> Data? {
        _ = osUsername
        fatalError("TODO: security find-generic-password -s <service> -a <user> -w")
    }
}
