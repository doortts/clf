import XCTest
import Foundation

/// 임시 디렉토리를 잡고 테스트가 끝나면 지운다.
class TempDirTestCase: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clfl-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        try super.tearDownWithError()
    }

    func read(_ name: String) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent(name))
    }
    func readJSON(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: read(name)) as? [String: Any])
    }
    func write(_ text: String, to name: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }
    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }
    func mode(_ name: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent(name).path)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
    }
    /// 디렉토리에 남은 파일 이름. 숨김 임시 파일까지 본다.
    func entries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }
}
