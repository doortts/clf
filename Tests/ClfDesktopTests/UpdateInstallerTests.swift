import XCTest
@testable import ClfDesktop

/// helper 스크립트 문자열과 spctl 판정.
///
/// 프로세스를 띄우지 않고 볼 수 있는 것만 여기서 잠근다. 마운트와 교체는
/// 손으로 본다. docs/design/14-self-update.html 9절
final class UpdateInstallerTests: XCTestCase {

    private let bundle = URL(fileURLWithPath: "/Users/me/Applications/clf.app")
    private let paths = UpdatePaths(
        cacheRoot: URL(fileURLWithPath: "/tmp/clf-test/update"),
        logRoot: URL(fileURLWithPath: "/tmp/clf-test/logs"))

    private func script(bundle: URL? = nil, tag: String = "v0.5.0") -> String {
        UpdateInstaller.helperScript(
            bundle: bundle ?? self.bundle,
            staged: paths.stagedApp(tag: tag),
            cache: paths.staging(tag: tag),
            log: paths.log(tag: tag),
            pid: 4321)
    }

    /// **이 줄이 빠지면 실패했을 때 아무것도 안 남는다.** helper 는 앱이 죽은
    /// 뒤에 돌아서 화면도 우리 프로세스도 없다.
    func test_scriptRedirectsEverythingToTheLog() {
        let text = script()
        XCTAssertTrue(text.contains("exec >>"), "출력을 파일로 돌려야 한다")
        XCTAssertTrue(text.contains("2>&1"), "표준 오류도 같이 가야 한다")
        XCTAssertTrue(text.contains("/tmp/clf-test/logs/update-v0.5.0.log"))
    }

    /// 공백과 인용부호가 든 경로가 진짜로 있다. 문법이 깨지면 교체가 통째로
    /// 안 돈다.
    func test_quotesSurviveOddPaths() {
        let odd = URL(fileURLWithPath: "/Users/me/My Apps/it's here/clf.app")
        let text = script(bundle: odd)
        XCTAssertTrue(text.contains(#"'/Users/me/My Apps/it'\''s here/clf.app'"#))
        // bash 가 문법을 받아들이는지 직접 물어본다. 문자열 검사만으로는
        // 인용을 한 겹 빠뜨린 것을 못 잡는다
        assertValidBash(text)
    }

    func test_quoteWrapsAndEscapes() {
        XCTAssertEqual(UpdateInstaller.quote("/a/b"), "'/a/b'")
        XCTAssertEqual(UpdateInstaller.quote("it's"), #"'it'\''s'"#)
    }

    /// 평범한 경로에서도 문법이 맞아야 한다.
    func test_scriptIsValidBash() {
        assertValidBash(script())
    }

    /// 돌고 있는 번들을 덮어쓰면 다음 실행이 깨진다. 부모를 기다려야 한다.
    func test_scriptWaitsForTheParentToDie() {
        let text = script()
        XCTAssertTrue(text.contains("kill -0 4321"))
        XCTAssertTrue(text.contains("\(UpdateInstaller.waitSteps)"))
    }

    /// `rm -rf` 뒤에 복사하면 그 사이에 helper 가 죽었을 때 번들이 없는 상태로
    /// 남는다. `mv` 두 번이라 어느 순간에도 실행할 수 있는 번들이 한 자리에 있다.
    func test_scriptSwapsWithTwoMovesAndNeverDeletesFirst() {
        let text = script()
        let new = "'/Users/me/Applications/clf.app.new'"
        let old = "'/Users/me/Applications/clf.app.old'"
        XCTAssertTrue(text.contains("ditto '/Users/me/Applications/clf.app' \(new)") == false,
                      "복사 원본은 받아 둔 번들이어야 한다")
        XCTAssertTrue(text.contains("mv '/Users/me/Applications/clf.app' \(old)"))
        XCTAssertTrue(text.contains("mv \(new) '/Users/me/Applications/clf.app'"))
        // 되돌리는 손. 두 번째 mv 가 실패하면 옛 번들을 제자리에 놓는다
        XCTAssertTrue(text.contains("mv \(old) '/Users/me/Applications/clf.app'"))
    }

    func test_scriptReopensAndCleansUp() {
        let text = script()
        XCTAssertTrue(text.contains("open '/Users/me/Applications/clf.app'"))
        XCTAssertTrue(text.contains("rm -rf '/tmp/clf-test/update/v0.5.0'"),
                      "성공했으면 받은 것을 지운다")
    }

    // MARK: spctl 판정

    /// **교체 전 평가가 이 설계의 유일한 안전장치다.**
    func test_onlyNotarizedDeveloperIDPasses() {
        XCTAssertTrue(UpdateInstaller.gatekeeperAccepted("""
        /tmp/clf.app: accepted
        source=Notarized Developer ID
        origin=Developer ID Application: Suwon Chae (ABCDE12345)
        """))
    }

    /// 서명만 우리 것이고 애플이 검사한 적은 없다는 뜻이다. 막는다.
    func test_unnotarizedDeveloperIDIsBlocked() {
        XCTAssertFalse(UpdateInstaller.gatekeeperAccepted("""
        /tmp/clf.app: accepted
        source=Developer ID
        """))
    }

    func test_rejectedAndEmptyAreBlocked() {
        XCTAssertFalse(UpdateInstaller.gatekeeperAccepted("/tmp/clf.app: rejected"))
        XCTAssertFalse(UpdateInstaller.gatekeeperAccepted(""))
        XCTAssertFalse(UpdateInstaller.gatekeeperAccepted("source=Notarized Developer ID"))
    }

    // MARK: 경로

    /// 태그는 응답이 준 문자열이다. `/` 가 든 태그는 실제로 있다.
    func test_tagsAreSanitizedForFilenames() {
        XCTAssertEqual(UpdateInstaller.slug("v0.5.0"), "v0.5.0")
        XCTAssertEqual(UpdateInstaller.slug("release/1.0"), "release-1.0")
        XCTAssertEqual(UpdateInstaller.slug(" v1.0.0 "), "v1.0.0")
        XCTAssertEqual(UpdateInstaller.slug("v1.0.0; rm -rf ~"), "v1.0.0--rm--rf--")
    }

    /// **`..` 하나가 통과하면 캐시의 부모를 가리킨다.** 그 자리를 helper 가
    /// `rm -rf` 로 지운다.
    func test_dotOnlyTagsCannotEscapeTheCache() {
        for tag in ["", "..", ".", "...", "../..", "-", "  "] {
            XCTAssertEqual(UpdateInstaller.slug(tag), "unknown", "\(tag) 는 이름이 아니다")
        }
        XCTAssertEqual(paths.staging(tag: "..").path, "/tmp/clf-test/update/unknown")
    }

    func test_pathsStayUnderTheirRoots() {
        XCTAssertEqual(paths.dmg(tag: "v0.5.0").path,
                       "/tmp/clf-test/update/v0.5.0/clf-v0.5.0.dmg")
        XCTAssertEqual(paths.stagedApp(tag: "v0.5.0").path,
                       "/tmp/clf-test/update/v0.5.0/clf.app")
        XCTAssertEqual(paths.mountPoint(tag: "v0.5.0").path,
                       "/tmp/clf-test/update/v0.5.0/.mount")
        XCTAssertEqual(paths.etag.path, "/tmp/clf-test/update/etag")
    }

    /// 캐시와 로그의 수명이 다르다. 교체 실패는 재부팅으로 조사하는 일이다.
    func test_logsLiveOutsideTheCache() {
        let real = UpdatePaths()
        XCTAssertTrue(real.cacheRoot.path.contains("Caches"))
        XCTAssertTrue(real.logRoot.path.contains("Logs"))
        XCTAssertFalse(real.logRoot.path.hasPrefix(real.cacheRoot.path))
    }

    // MARK: 도우미

    /// `bash -n` 으로 문법만 검사한다. 아무것도 실행하지 않는다.
    private func assertValidBash(_ text: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clf-helper-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-n", url.path]
            let pipe = Pipe()
            process.standardError = pipe
            try process.run()
            let complaint = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                                   as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0,
                           "bash 문법 오류: \(complaint)", file: file, line: line)
        } catch {
            XCTFail("검사를 못 돌렸다: \(error)", file: file, line: line)
        }
    }
}
