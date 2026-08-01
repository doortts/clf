import Foundation
import ClflCore

/// accounts.json. 조직 메타데이터와 우선순위 배열.
///
/// 우선순위를 별도 배열로 두는 이유는 UI 의 드래그 재정렬이 그 배열만 다시 쓰면
/// 되기 때문이다. accounts 에 없는 id 가 priority 에 있으면 로드 시 걸러낸다.
public struct AccountsDocument: Codable, Sendable, Equatable {
    public var version: Int
    public var priority: [AccountID]
    public var accounts: [AccountID: Account]

    public init(version: Int = 1, priority: [AccountID] = [], accounts: [AccountID: Account] = [:]) {
        self.version = version
        self.priority = priority
        self.accounts = accounts
    }

    /// 파일이 손으로 편집됐거나 반쯤 쓰인 상태에서도 선택기가 읽을 수 있는 모양으로
    /// 맞춘다. priority 는 유일해야 하고, accounts 의 모든 id 를 정확히 한 번 담아야
    /// 한다. 빠진 조직을 뒤에 붙이지 않으면 등록은 됐는데 영영 선택되지 않는다.
    public mutating func normalize() {
        var seen = Set<AccountID>()
        priority = priority.filter { accounts[$0] != nil && seen.insert($0).inserted }
        priority += accounts.keys.filter { !seen.contains($0) }.sorted()
    }
}

public actor AccountsFile {
    private let url: URL

    public init(directory: URL) {
        self.url = directory.appendingPathComponent("accounts.json")
    }

    /// 파일이 없으면 빈 문서다. 깨졌으면 던진다.
    ///
    /// runtime.json 과 다른 선택이다. 런타임은 다시 관측하면 되지만 등록한 조직
    /// 목록은 사용자가 손으로 넣은 것이라, 조용히 빈 문서로 시작했다가 다음 저장에서
    /// 덮어쓰면 그대로 사라진다.
    public func load() throws -> AccountsDocument {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return AccountsDocument()
        }
        guard var doc = try? makeDecoder().decode(AccountsDocument.self, from: data) else {
            throw StoreError.corruptFile(url)
        }
        doc.normalize()
        return doc
    }

    public func save(_ doc: AccountsDocument) throws {
        var doc = doc
        doc.normalize()
        try atomicWrite(makeEncoder().encode(doc), to: url)
    }
}
