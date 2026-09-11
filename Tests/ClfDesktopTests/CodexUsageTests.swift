import XCTest
@testable import ClfDesktop

/// Codex Usage API 응답을 읽는다. 아래 JSON 은 실제 응답에서 옮겼다.
/// docs/design/18-codex-usage.md 1절
final class CodexUsageTests: XCTestCase {

    /// `plus` 플랜. 5시간과 주간 둘. 2026-09-04 세션 기록에서.
    let plus = Data("""
    {"plan_type": "plus",
     "rate_limit": {"allowed": true, "limit_reached": false,
       "primary_window":   {"used_percent": 49.0, "limit_window_seconds": 18000,
                            "reset_after_seconds": 9600, "reset_at": 1788462824},
       "secondary_window": {"used_percent": 93, "limit_window_seconds": 604800,
                            "reset_after_seconds": 387060, "reset_at": 1788840284}},
     "credits": {"has_credits": false, "unlimited": false, "balance": "0"},
     "rate_limit_reached_type": null}
    """.utf8)

    /// `prolite` 플랜. primary 가 주간이고 secondary 는 없다. 2026-09-11 실측.
    let prolite = Data("""
    {"plan_type": "prolite",
     "rate_limit": {"allowed": true, "limit_reached": false,
       "primary_window":   {"used_percent": 9, "limit_window_seconds": 604800,
                            "reset_after_seconds": 585945, "reset_at": 1789706432},
       "secondary_window": null},
     "additional_rate_limits": [
       {"limit_name": "GPT-5.3-Codex-Spark",
        "rate_limit": {"primary_window": {"used_percent": 0, "limit_window_seconds": 18000,
                                          "reset_at": 1789138488}}}]}
    """.utf8)

    func test_plusMapsByWindowLength() throws {
        let report = try parseCodexUsage(plus)
        XCTAssertEqual(report.plan, "plus")
        XCTAssertEqual(report.limits[.session]?.percentUsed, 49)
        XCTAssertEqual(report.limits[.weeklyAll]?.percentUsed, 93)
        XCTAssertNil(report.limits[.weeklyScoped])
        XCTAssertEqual(report.limits[.session]?.resetsAt?.timeIntervalSince1970, 1_788_462_824)
    }

    /// 자리(primary)로 읽으면 주간이 5시간 줄에 앉는다. 길이로 읽어야 한다.
    func test_proliteWeeklyPrimaryLandsOnWeeklyRow() throws {
        let report = try parseCodexUsage(prolite)
        XCTAssertEqual(report.plan, "prolite")
        XCTAssertNil(report.limits[.session], "5시간 창은 없는 것이다. 못 읽은 것이 아니다")
        XCTAssertEqual(report.limits[.weeklyAll]?.percentUsed, 9)
        XCTAssertEqual(report.limits[.weeklyAll]?.percentRemaining, 91)
    }

    /// 사용률 0 인 창의 reset_at 은 지금 + 창 길이라 뜻이 없다. Claude 처럼
    /// "창 안 열림" 으로 가려면 nil 이어야 한다.
    func test_zeroUsageDropsReset() throws {
        let idle = Data("""
        {"rate_limit": {"primary_window": {"used_percent": 0, "limit_window_seconds": 18000,
                                           "reset_at": 1789138488}}}
        """.utf8)
        let report = try parseCodexUsage(idle)
        XCTAssertEqual(report.limits[.session]?.percentUsed, 0)
        XCTAssertNil(report.limits[.session]?.resetsAt)
    }

    /// 모르는 길이도 86400 을 기준으로 갈린다. 죽지 않는다.
    func test_unknownWindowLengthFallsOnEitherSide() throws {
        let odd = Data("""
        {"rate_limit": {"primary_window":   {"used_percent": 5, "limit_window_seconds": 3600,
                                             "reset_at": 1789138488},
                        "secondary_window": {"used_percent": 7, "limit_window_seconds": 2592000,
                                             "reset_at": 1789138488}}}
        """.utf8)
        let report = try parseCodexUsage(odd)
        XCTAssertEqual(report.limits[.session]?.percentUsed, 5)
        XCTAssertEqual(report.limits[.weeklyAll]?.percentUsed, 7)
    }

    func test_rejectsNonObject() {
        XCTAssertThrowsError(try parseCodexUsage(Data("[]".utf8)))
    }

    // MARK: auth.json

    func test_readsTokenAndAccount() throws {
        let auth = try parseCodexAuth(Data("""
        {"auth_mode": "chatgpt", "OPENAI_API_KEY": null,
         "tokens": {"id_token": "a", "access_token": "eyJ.b", "refresh_token": "rt",
                    "account_id": "0f0e0d0c-0b0a-4c00-8000-000000000001"},
         "last_refresh": "2026-09-11T04:40:35Z"}
        """.utf8))
        XCTAssertEqual(auth.token, "eyJ.b")
        XCTAssertEqual(auth.accountID, "0f0e0d0c-0b0a-4c00-8000-000000000001")
    }

    /// API 키 모드로 로그인한 파일에는 토큰이 없다. 읽을 것이 없다고 말한다.
    func test_apiKeyModeHasNoToken() {
        XCTAssertThrowsError(try parseCodexAuth(Data("""
        {"auth_mode": "apikey", "OPENAI_API_KEY": "sk-...", "tokens": null}
        """.utf8)))
    }

    // MARK: 리더

    struct FakeCodex: CodexUsageFetching {
        var report: CodexReport?
        var error: UsageFetchError?
        func usage(token: String, accountID: String) async throws -> CodexReport {
            if let error { throw error }
            return report!
        }
    }

    private func home(with auth: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clf-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let auth {
            try Data(auth.utf8).write(to: dir.appendingPathComponent("auth.json"))
        }
        return dir
    }

    let auth = """
    {"tokens": {"access_token": "t", "account_id": "acct-1"}}
    """

    func test_noAuthFileIsEmptyNotError() async throws {
        let reader = CodexReader(home: try home(with: nil), session: FakeCodex())
        XCTAssertFalse(reader.isInstalled)
        let result = await reader.read()
        XCTAssertEqual(result, .empty)
    }

    func test_readBuildsCodexOrg() async throws {
        let report = try parseCodexUsage(plus)
        let reader = CodexReader(home: try home(with: auth), session: FakeCodex(report: report))
        let result = await reader.read()
        let org = try XCTUnwrap(result.orgs.first)
        XCTAssertEqual(org.uuid, "acct-1")
        XCTAssertEqual(org.name, "Codex")
        XCTAssertEqual(org.provider, .codex)
        XCTAssertEqual(org.plan, "plus")
        XCTAssertFalse(org.isActive)
        XCTAssertEqual(org.rowKinds, [.session, .weeklyAll])
    }

    /// 429 와 끊김은 Claude 와 같은 갈래로 올라간다. ReadGate 가 한 자리에서 본다.
    func test_throttledAndOfflineSurface() async throws {
        let dir = try home(with: auth)
        let throttled = await CodexReader(
            home: dir, session: FakeCodex(error: UsageFetchError(description: "429", throttled: true))
        ).read()
        XCTAssertTrue(throttled.throttled)
        XCTAssertEqual(throttled.orgs.first?.error, "429")
        XCTAssertFalse(throttled.orgs.first?.hasUsage ?? true)

        let offline = await CodexReader(home: dir, session: FakeCodex(error: .noNetwork)).read()
        XCTAssertTrue(offline.offline)
    }

    // MARK: 화면 규칙

    func test_labelsDifferOnlyOnWeeklyRow() {
        XCTAssertEqual(LimitKind.weeklyAll.label(for: .claude), "주간 전체")
        XCTAssertEqual(LimitKind.weeklyAll.label(for: .codex), "주간")
        XCTAssertEqual(LimitKind.session.label(for: .codex), LimitKind.session.label)
    }

    /// Claude 는 셋 고정, Codex 는 있는 줄만.
    func test_rowKinds() throws {
        let weekly = try parseCodexUsage(prolite).limits
        let codex = OrgUsage(uuid: "c", name: "Codex", isActive: false, plan: "prolite",
                             provider: .codex, limits: weekly)
        XCTAssertEqual(codex.rowKinds, [.weeklyAll])
        let claude = OrgUsage(uuid: "a", name: "T40", isActive: true, plan: "team", limits: weekly)
        XCTAssertEqual(claude.rowKinds, LimitKind.allCases)
    }

    func test_barCodeForCodex() {
        XCTAssertEqual(BarText.codes(for: ["NAVER_TEAM_40", "Codex"]),
                       ["NAVER_TEAM_40": "T40", "Codex": "Co"])
    }

    /// 순서를 안 정했으면 Claude 활성 -> Claude 이름순 -> Codex.
    func test_defaultOrderPutsCodexLast() {
        let codex = OrgUsage(uuid: "c", name: "Codex", isActive: false, plan: nil,
                             provider: .codex, limits: [:])
        let a = OrgUsage(uuid: "a", name: "Zeta", isActive: false, plan: nil, limits: [:])
        let b = OrgUsage(uuid: "b", name: "Alpha", isActive: true, plan: nil, limits: [:])
        XCTAssertEqual(DesktopPreferences().apply(to: [codex, a, b]).map(\.name),
                       ["Alpha", "Zeta", "Codex"])
        // 정했으면 그쪽이 이긴다
        var prefs = DesktopPreferences()
        prefs.order = ["c", "a", "b"]
        XCTAssertEqual(prefs.apply(to: [codex, a, b]).map(\.name), ["Codex", "Zeta", "Alpha"])
    }

    /// 지난 값을 물려줄 때 공급자가 Claude 로 되돌아가면 Codex 카드가 Claude
    /// 단추를 달고 나온다.
    func test_mergeAndStaleKeepProvider() {
        let good = OrgUsage(uuid: "c", name: "Codex", isActive: false, plan: "plus",
                            provider: .codex,
                            limits: [.session: UsageLimit(percentUsed: 1, resetsAt: nil, severity: "")])
        let failed = OrgUsage(uuid: "c", name: "Codex", isActive: false, plan: nil,
                              provider: .codex, limits: [:], error: "429")
        let merged = mergeKeepingLastGood(fresh: [failed], previous: [good])
        XCTAssertEqual(merged.first?.provider, .codex)
        XCTAssertTrue(merged.first?.isStale ?? false)
        XCTAssertEqual(merged.first?.plan, "plus")

        let stale = markStale([good], error: "앱을 못 읽었다")
        XCTAssertEqual(stale.first?.provider, .codex)
        XCTAssertTrue(stale.first?.isStale ?? false)
        XCTAssertEqual(stale.first?.error, "앱을 못 읽었다")
        XCTAssertEqual(reassignActive(to: nil, in: [good]).first?.provider, .codex)
    }
}
