import XCTest
import ClfCore
@testable import ClfStore

private let T0 = Date(timeIntervalSince1970: 1_700_000_000)

private func acct(_ id: String, plan: Plan = .team) -> Account {
    Account(id: id, plan: plan, credentialKind: .oauth, tokenCreatedAt: T0,
            tokenFingerprint: "fp-\(id)")
}

final class AccountsFileTests: TempDirTestCase {
    func test_missingFileLoadsAsEmptyDocument() async throws {
        let doc = try await AccountsFile(directory: dir).load()
        XCTAssertEqual(doc, AccountsDocument())
    }

    func test_roundTrip() async throws {
        let file = AccountsFile(directory: dir)
        let doc = AccountsDocument(priority: ["b", "a"],
                                   accounts: ["a": acct("a"), "b": acct("b", plan: .enterprise)])
        try await file.save(doc)
        let loaded = try await file.load()
        XCTAssertEqual(loaded, doc)
    }

    /// 등록 목록은 사용자가 손으로 넣은 것이다. 조용히 빈 문서로 시작했다가 다음
    /// 저장에서 덮어쓰면 그대로 사라진다.
    func test_corruptFileThrowsRatherThanReturningEmpty() async throws {
        try write("{ this is not json", to: "accounts.json")
        do {
            _ = try await AccountsFile(directory: dir).load()
            XCTFail("깨진 파일은 던져야 한다")
        } catch StoreError.corruptFile {
            // 기대한 경로
        }
    }

    func test_dropsPriorityEntriesWithNoAccount() {
        var doc = AccountsDocument(priority: ["ghost", "a"], accounts: ["a": acct("a")])
        doc.normalize()
        XCTAssertEqual(doc.priority, ["a"])
    }

    func test_dropsDuplicatePriorityEntries() {
        var doc = AccountsDocument(priority: ["a", "a"], accounts: ["a": acct("a")])
        doc.normalize()
        XCTAssertEqual(doc.priority, ["a"])
    }

    /// 빠진 조직을 뒤에 붙이지 않으면 등록은 됐는데 영영 선택되지 않는다.
    func test_appendsAccountsMissingFromPriority() {
        var doc = AccountsDocument(priority: ["b"],
                                   accounts: ["a": acct("a"), "b": acct("b"), "c": acct("c")])
        doc.normalize()
        XCTAssertEqual(doc.priority, ["b", "a", "c"], "기존 순서는 지키고 나머지는 이름순")
    }

    func test_saveNormalizesBeforeWriting() async throws {
        let file = AccountsFile(directory: dir)
        try await file.save(AccountsDocument(priority: ["ghost"], accounts: ["a": acct("a")]))
        let loaded = try await file.load()
        XCTAssertEqual(loaded.priority, ["a"])
    }

    func test_fileIsHumanReadableAndOwnerOnly() async throws {
        try await AccountsFile(directory: dir).save(
            AccountsDocument(accounts: ["a": acct("a")]))
        XCTAssertEqual(try mode("accounts.json"), 0o600)
        let text = String(decoding: try read("accounts.json"), as: UTF8.self)
        XCTAssertTrue(text.contains("\n"), "prettyPrinted 라야 손으로 고칠 수 있다")
    }
}
