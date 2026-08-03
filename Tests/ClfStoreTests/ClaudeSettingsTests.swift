import XCTest
@testable import ClfStore

private let ourURL = URL(string: "http://127.0.0.1:51710")!

final class ClaudeSettingsTests: TempDirTestCase {
    var config: URL!
    var state: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        config = dir.appendingPathComponent("claude", isDirectory: true)
        state = dir.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    }

    func makeSettings() throws -> ClaudeSettingsFile {
        try ClaudeSettingsFile(configDirectory: config, stateDirectory: state)
    }
    func writeSettings(_ json: String) throws {
        try Data(json.utf8).write(to: config.appendingPathComponent("settings.json"))
    }
    func settingsJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: config.appendingPathComponent("settings.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func env() throws -> [String: String] {
        (try settingsJSON()["env"] as? [String: String]) ?? [:]
    }
    var backupExists: Bool {
        FileManager.default.fileExists(
            atPath: config.appendingPathComponent("settings.json.clf.bak").path)
    }

    // MARK: install

    func test_installWritesBothKeys() throws {
        try makeSettings().install(baseURL: ourURL, enableToolSearch: true, force: false)
        XCTAssertEqual(try env(), ["ANTHROPIC_BASE_URL": ourURL.absoluteString,
                                   "ENABLE_TOOL_SEARCH": "true"])
    }

    /// 사용자가 꺼진 것을 눈치채고 설정을 뒤지게 만들면 진 것이다.
    func test_enableToolSearchIsWrittenByDefault() throws {
        try makeSettings().install(baseURL: ourURL, enableToolSearch: true, force: false)
        XCTAssertEqual(try env()["ENABLE_TOOL_SEARCH"], "true")
    }

    /// 사용자의 hooks, statusLine, permissions, model 을 절대 잃지 않는다.
    func test_installPreservesUnknownKeys() throws {
        try writeSettings("""
        {"model":"opus","permissions":{"allow":["Bash"]},
         "hooks":{"PreToolUse":[{"matcher":"Bash"}]},
         "statusLine":{"type":"command","command":"x"},
         "env":{"MY_OWN":"keep"}}
        """)
        try makeSettings().install(baseURL: ourURL, enableToolSearch: true, force: false)

        let json = try settingsJSON()
        XCTAssertEqual(json["model"] as? String, "opus")
        XCTAssertNotNil(json["permissions"])
        XCTAssertNotNil(json["hooks"])
        XCTAssertNotNil(json["statusLine"])
        XCTAssertEqual(try env()["MY_OWN"], "keep", "env 안의 남의 키도 남는다")
    }

    func test_installCreatesBackupBeforeFirstWrite() throws {
        try writeSettings(#"{"model":"opus"}"#)
        XCTAssertFalse(backupExists)
        try makeSettings().install(baseURL: ourURL, enableToolSearch: true, force: false)
        XCTAssertTrue(backupExists)

        let backup = try Data(contentsOf: config.appendingPathComponent("settings.json.clf.bak"))
        let restored = try XCTUnwrap(
            JSONSerialization.jsonObject(with: backup) as? [String: Any])
        XCTAssertNil(restored["env"], "백업은 우리가 손대기 전 모습이어야 한다")
    }

    func test_backupIsNotOverwrittenBySecondInstall() throws {
        try writeSettings(#"{"model":"opus"}"#)
        let settings = try makeSettings()
        try settings.install(baseURL: ourURL, enableToolSearch: true, force: false)
        try settings.install(baseURL: ourURL, enableToolSearch: true, force: false)

        let backup = try Data(contentsOf: config.appendingPathComponent("settings.json.clf.bak"))
        let restored = try XCTUnwrap(
            JSONSerialization.jsonObject(with: backup) as? [String: Any])
        XCTAssertNil(restored["env"], "두 번째 설치가 백업을 우리 값으로 덮으면 안 된다")
    }

    func test_installRefusesWhenAnotherValuePresent() throws {
        try writeSettings(#"{"env":{"ANTHROPIC_BASE_URL":"http://someone-else:9000"}}"#)
        do {
            try makeSettings().install(baseURL: ourURL, enableToolSearch: true, force: false)
            XCTFail("남의 값 위에 조용히 쓰면 안 된다")
        } catch StoreError.settingsConflict(let key, let existing) {
            XCTAssertEqual(key, "ANTHROPIC_BASE_URL")
            XCTAssertEqual(existing, "http://someone-else:9000")
        }
        XCTAssertEqual(try env()["ANTHROPIC_BASE_URL"], "http://someone-else:9000",
                       "거부했으면 파일도 그대로여야 한다")
    }

    func test_forceOverwritesConflictingValue() throws {
        try writeSettings(#"{"env":{"ANTHROPIC_BASE_URL":"http://someone-else:9000"}}"#)
        try makeSettings().install(baseURL: ourURL, enableToolSearch: true, force: true)
        XCTAssertEqual(try env()["ANTHROPIC_BASE_URL"], ourURL.absoluteString)
    }

    /// 포트가 바뀌어 우리 값을 우리가 다시 쓰는 것은 충돌이 아니다.
    func test_reinstallWithSameValueIsNotAConflict() throws {
        let settings = try makeSettings()
        try settings.install(baseURL: ourURL, enableToolSearch: true, force: false)
        try settings.install(baseURL: ourURL, enableToolSearch: true, force: false)
        XCTAssertEqual(try env()["ANTHROPIC_BASE_URL"], ourURL.absoluteString)
    }

    /// 사용자가 열어보고 손으로 고치는 파일이다. URL 이 "http:\\/\\/" 로 적히면 안 된다.
    func test_urlIsWrittenWithoutSlashEscapes() throws {
        try makeSettings().install(baseURL: ourURL, enableToolSearch: true, force: false)
        let raw = String(decoding:
            try Data(contentsOf: config.appendingPathComponent("settings.json")), as: UTF8.self)
        XCTAssertTrue(raw.contains("http://127.0.0.1:51710"), "받은 원문:\n\(raw)")
        XCTAssertFalse(raw.contains("\\/"))
    }

    // MARK: read

    func test_readManagedBaseURL() throws {
        let settings = try makeSettings()
        XCTAssertNil(try settings.readManagedBaseURL())
        try settings.install(baseURL: ourURL, enableToolSearch: true, force: false)
        XCTAssertEqual(try settings.readManagedBaseURL(), ourURL)
    }

    // MARK: uninstall

    /// 앱을 끄면 Claude Code 가 고장 나는 것이 아니라 원래대로 돌아가야 한다.
    func test_uninstallRemovesOnlyOurKeys() throws {
        try writeSettings(#"{"model":"opus","env":{"MY_OWN":"keep"}}"#)
        let settings = try makeSettings()
        try settings.install(baseURL: ourURL, enableToolSearch: true, force: false)
        try settings.uninstall()

        XCTAssertEqual(try env(), ["MY_OWN": "keep"])
        XCTAssertEqual(try settingsJSON()["model"] as? String, "opus")
    }

    /// 사용자가 일부러 꺼둔 값을 우리 설치가 삼키면 안 된다.
    func test_uninstallRestoresPreexistingToolSearchValue() throws {
        try writeSettings(#"{"env":{"ENABLE_TOOL_SEARCH":"false"}}"#)
        let settings = try makeSettings()
        try settings.install(baseURL: ourURL, enableToolSearch: true, force: false)
        XCTAssertEqual(try env()["ENABLE_TOOL_SEARCH"], "true")

        try settings.uninstall()
        XCTAssertEqual(try env()["ENABLE_TOOL_SEARCH"], "false")
    }

    func test_uninstallDropsEnvBlockItCreated() throws {
        try writeSettings(#"{"model":"opus"}"#)
        let settings = try makeSettings()
        try settings.install(baseURL: ourURL, enableToolSearch: true, force: false)
        try settings.uninstall()
        XCTAssertNil(try settingsJSON()["env"], "우리 때문에 생긴 빈 블록을 남기지 않는다")
    }

    func test_uninstallWithoutInstallIsHarmless() throws {
        try writeSettings(#"{"model":"opus"}"#)
        try makeSettings().uninstall()
        XCTAssertEqual(try settingsJSON()["model"] as? String, "opus")
    }

    // MARK: 설정 디렉토리

    func test_configDirectoryHonorsClaudeConfigDirEnvironment() throws {
        let previous = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        defer {
            if let previous { setenv("CLAUDE_CONFIG_DIR", previous, 1) }
            else { unsetenv("CLAUDE_CONFIG_DIR") }
        }
        setenv("CLAUDE_CONFIG_DIR", config.path, 1)
        XCTAssertEqual(try ClaudeSettingsFile.defaultConfigDirectory().path, config.path)

        unsetenv("CLAUDE_CONFIG_DIR")
        XCTAssertTrue(try ClaudeSettingsFile.defaultConfigDirectory().path.hasSuffix("/.claude"))
    }

    func test_corruptSettingsRefusesRatherThanClobbering() throws {
        try writeSettings("{ not json")
        do {
            try makeSettings().install(baseURL: ourURL, enableToolSearch: true, force: false)
            XCTFail("깨진 설정 위에 새로 쓰면 사용자 설정이 통째로 날아간다")
        } catch StoreError.corruptFile {
            // 기대한 경로
        }
    }
}
