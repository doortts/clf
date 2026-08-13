import XCTest
@testable import ClfDesktop

/// 자동 재개 설정의 저장과 읽기. 옛 파일도 읽혀야 한다.
final class AutoResumePrefsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auto-resume-prefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testDefaultIsOff() {
        XCTAssertNil(DesktopPreferences().autoResume)
    }

    func testRoundTrip() throws {
        let file = try DesktopPreferencesFile(directory: dir)
        var prefs = DesktopPreferences()
        prefs.autoResume = AutoResumePlan(orgUUID: "t52", sessionID: "abc-123",
                                          cwd: "/Users/me/repo", title: "제목",
                                          prompt: "계속해")
        try file.save(prefs)
        XCTAssertEqual(file.load().autoResume, prefs.autoResume)
    }

    func testTurningItOffPersists() throws {
        let file = try DesktopPreferencesFile(directory: dir)
        var prefs = DesktopPreferences()
        prefs.autoResume = AutoResumePlan(orgUUID: "t52", sessionID: "a", cwd: "/tmp",
                                          title: "제목")
        try file.save(prefs)
        prefs.autoResume = nil
        try file.save(prefs)
        XCTAssertNil(file.load().autoResume)
    }

    /// 이 항목이 없던 시절의 파일. 설정 하나 때문에 나머지를 잃으면 안 된다.
    func testOldFileWithoutTheFieldStillLoads() throws {
        let url = dir.appendingPathComponent("desktop.json")
        try #"{"version":1,"hidden":["ent"],"notify":false}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let prefs = try DesktopPreferencesFile(directory: dir).load()
        XCTAssertNil(prefs.autoResume)
        XCTAssertEqual(prefs.hidden, ["ent"])
        XCTAssertFalse(prefs.notify)
    }

    /// 항목이 깨져 있어도 나머지 설정은 살아야 한다.
    func testBrokenPlanDoesNotSinkTheRest() throws {
        let url = dir.appendingPathComponent("desktop.json")
        try #"{"version":1,"hidden":["ent"],"autoResume":{"orgUUID":"t52"}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let prefs = try DesktopPreferencesFile(directory: dir).load()
        XCTAssertNil(prefs.autoResume)
        XCTAssertEqual(prefs.hidden, ["ent"])
    }

    func testPromptDefaultsToTheStockLine() {
        let plan = AutoResumePlan(orgUUID: "t", sessionID: "s", cwd: "/tmp", title: "제목")
        XCTAssertEqual(plan.prompt, AutoResumePlan.defaultPrompt)
    }
}
