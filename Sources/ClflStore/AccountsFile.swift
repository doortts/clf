import Foundation
import ClflCore

/// accounts.json. 조직 메타데이터와 우선순위 배열.
///
/// 우선순위를 별도 배열로 두는 이유는 UI 의 드래그 재정렬이 그 배열만 다시 쓰면
/// 되기 때문이다. accounts 에 없는 id 가 priority 에 있으면 로드 시 걸러낸다.
public struct AccountsDocument: Codable, Sendable {
    public var version: Int
    public var priority: [AccountID]
    public var accounts: [AccountID: Account]

    public init(version: Int = 1, priority: [AccountID] = [], accounts: [AccountID: Account] = [:]) {
        self.version = version
        self.priority = priority
        self.accounts = accounts
    }
}

public actor AccountsFile {
    public init(directory: URL) { _ = directory; fatalError("TODO") }

    public func load() throws -> AccountsDocument { fatalError("TODO") }
    public func save(_ doc: AccountsDocument) throws { _ = doc; fatalError("TODO") }
}
