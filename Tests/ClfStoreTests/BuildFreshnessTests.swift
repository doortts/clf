import XCTest
@testable import ClfStore

/// 개발용 바이너리가 소스보다 낡았는지 본다.
///
/// 심볼릭 링크가 `.build` 를 직접 가리켜서 조용히 낡는다. 디버그 빌드로
/// 검증해놓고 릴리스를 안 올리면 다음 실행에서 옛 동작을 본다.
final class BuildFreshnessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("freshness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/Thing"), withIntermediateDirectories: true)
        try write("Package.swift", "// swift-tools-version:6.0")
        try write("Sources/Thing/A.swift", "let a = 1")
        // 방금 만들었으므로 전부 지금 시각이다. 기준을 과거로 내려둔다
        try touch("Package.swift", Date(timeIntervalSince1970: 1_000_000))
        try touch("Sources/Thing/A.swift", Date(timeIntervalSince1970: 1_000_000))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    private func touch(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: root.appendingPathComponent(path).path)
    }

    private func binary(at date: Date) throws -> URL {
        let url = root.appendingPathComponent("clfctl-fake")
        try Data("bin".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: url.path)
        return url
    }

    private let old = Date(timeIntervalSince1970: 1_000_000)
    private let new = Date(timeIntervalSince1970: 2_000_000)

    func test_silentWhenBinaryIsNewer() throws {
        try touch("Sources/Thing/A.swift", old)
        XCTAssertNil(BuildFreshness.warning(executable: try binary(at: new), sourceRoot: root))
    }

    func test_warnsWhenSourceIsNewer() throws {
        let bin = try binary(at: old)
        try touch("Sources/Thing/A.swift", new)
        let warning = try XCTUnwrap(BuildFreshness.warning(executable: bin, sourceRoot: root))
        XCTAssertTrue(warning.contains("swift build"), warning)
    }

    /// 얼마나 낡았는지 읽을 수 있는 단위로 말한다.
    func test_agePicksAReadableUnit() {
        XCTAssertEqual(BuildFreshness.age(seconds: 90), "1분")
        XCTAssertEqual(BuildFreshness.age(seconds: 3 * 3600 + 60), "3시간")
        XCTAssertEqual(BuildFreshness.age(seconds: 5 * 86400), "5일")
        // 1분도 안 됐는데 낡았다고 하면 이상하다. 그래도 낡은 건 낡은 것이다
        XCTAssertEqual(BuildFreshness.age(seconds: 20), "1분 안쪽")
    }

    /// Package.swift 만 바뀌어도 낡은 것이다. 타겟이 바뀌었을 수 있다.
    func test_manifestCountsToo() throws {
        let bin = try binary(at: old)
        try touch("Sources/Thing/A.swift", old)
        try touch("Package.swift", new)
        XCTAssertNotNil(BuildFreshness.warning(executable: bin, sourceRoot: root))
    }

    /// .build 는 항상 최신이라 세면 늘 낡았다고 나온다.
    func test_ignoresBuildDirectory() throws {
        try touch("Sources/Thing/A.swift", old)
        let bin = try binary(at: new)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build"), withIntermediateDirectories: true)
        try write(".build/artifact", "x")
        try touch(".build/artifact", Date(timeIntervalSince1970: 3_000_000))
        XCTAssertNil(BuildFreshness.warning(executable: bin, sourceRoot: root))
    }

    /// 배포된 바이너리 옆에는 소스가 없다. 그때는 아무 말도 하지 않는다.
    func test_silentWithoutSourceTree() throws {
        let bin = try binary(at: old)
        let elsewhere = root.appendingPathComponent("nowhere")
        XCTAssertNil(BuildFreshness.warning(executable: bin, sourceRoot: elsewhere))
    }

    /// Package.swift 가 없으면 패키지 루트가 아니다. 남의 디렉토리를 뒤지지 않는다.
    func test_silentWhenNotAPackageRoot() throws {
        let bin = try binary(at: old)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Package.swift"))
        try touch("Sources/Thing/A.swift", new)
        XCTAssertNil(BuildFreshness.warning(executable: bin, sourceRoot: root))
    }

    /// 바이너리가 없어도 죽지 않는다. 검사 하나 때문에 도구가 안 뜨면 안 된다.
    func test_silentWhenExecutableIsMissing() throws {
        try touch("Sources/Thing/A.swift", new)
        XCTAssertNil(BuildFreshness.warning(
            executable: root.appendingPathComponent("없는파일"), sourceRoot: root))
    }

    /// 소스 루트는 컴파일 시점 경로에서 온다. 이 저장소에서 돌리면 찾아야 한다.
    func test_findsItsOwnPackageRoot() throws {
        let root = try XCTUnwrap(BuildFreshness.packageRoot)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Package.swift").path))
    }
}
