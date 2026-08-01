import XCTest
@testable import ClflStore

final class AtomicWriteTests: TempDirTestCase {
    func test_writesWithOwnerOnlyMode() throws {
        try atomicWrite(Data("hi".utf8), to: dir.appendingPathComponent("f.json"))
        XCTAssertEqual(try mode("f.json"), 0o600)
    }

    func test_replacesExistingFile() throws {
        let url = dir.appendingPathComponent("f.json")
        try atomicWrite(Data("old".utf8), to: url)
        try atomicWrite(Data("new".utf8), to: url)
        XCTAssertEqual(String(decoding: try read("f.json"), as: UTF8.self), "new")
    }

    /// 임시 파일이 남으면 다음 시작 때 디렉토리가 쓰레기로 찬다.
    func test_leavesNoTemporaryFileBehind() throws {
        try atomicWrite(Data("x".utf8), to: dir.appendingPathComponent("f.json"))
        XCTAssertEqual(try entries(), ["f.json"])
    }

    func test_createsMissingIntermediateDirectories() throws {
        let nested = dir.appendingPathComponent("a/b/c.json")
        try atomicWrite(Data("x".utf8), to: nested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }
}
