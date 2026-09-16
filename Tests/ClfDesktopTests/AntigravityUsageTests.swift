import XCTest
@testable import ClfDesktop

/// Antigravity 의 로컬 RPC 응답을 읽는다. 아래 JSON 은 실제 응답에서 옮겼다.
/// docs/design/19-antigravity-usage.md
final class AntigravityUsageTests: XCTestCase {

    /// `Pro` 플랜. 묶음 둘에 칸 넷. 2026-09-16 실측.
    let pro = Data("""
    {"response": {
      "groups": [
        {"displayName": "Gemini Models",
         "description": "Models within this group: Gemini Flash, Gemini Pro",
         "buckets": [
           {"bucketId": "gemini-weekly", "displayName": "Weekly Limit Remaining",
            "window": "weekly", "remainingFraction": 0.85,
            "resetTime": "2026-09-23T08:01:03Z"},
           {"bucketId": "gemini-5h", "displayName": "Five Hour Limit Remaining",
            "window": "5h", "remainingFraction": 0.38,
            "resetTime": "2026-09-16T13:01:03Z"}]},
        {"displayName": "Claude and GPT models",
         "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
         "buckets": [
           {"bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.22,
            "resetTime": "2026-09-23T08:01:03Z"},
           {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.71,
            "resetTime": "2026-09-16T13:01:03Z"}]}
      ],
      "description": "Within each group, models share a weekly limit and a 5-hour limit."
    }}
    """.utf8)

    /// 둘째 묶음은 Antigravity 안에서 Claude 나 GPT 를 골라 쓸 때만 닳는 별도
    /// 주머니다. 카드에 올리지 않으므로 해석 자리에서 버린다.
    func test_keepsGeminiGroupOnly() throws {
        let limits = try parseAntigravityUsage(pro)
        XCTAssertEqual(limits.count, 2)
        XCTAssertNotNil(limits[.session])
        XCTAssertNotNil(limits[.weeklyAll])
        XCTAssertNil(limits[.weeklyScoped], "3p 묶음은 안 들어온다")
    }

    /// 서버가 주는 값이 잔여다. Claude 와 Codex 는 사용률을 준다. 방향이 반대다.
    func test_derivesUsedFromRemainingFraction() throws {
        let limits = try parseAntigravityUsage(pro)
        XCTAssertEqual(limits[.session]?.percentUsed, 62)
        XCTAssertEqual(limits[.session]?.percentRemaining, 38)
        XCTAssertEqual(limits[.weeklyAll]?.percentUsed, 15)
    }

    func test_readsResetTime() throws {
        let limits = try parseAntigravityUsage(pro)
        XCTAssertEqual(limits[.session]?.resetsAt?.timeIntervalSince1970, 1_789_563_663)
    }

    /// 잔여가 1 이면 서버가 주는 리셋 시각이 `지금 + 창 길이` 라 흐른다.
    /// 타이머가 안 걸린 창이므로 Codex 와 같이 버린다.
    func test_untouchedWindowDropsReset() throws {
        let idle = Data("""
        {"response": {"groups": [{"displayName": "Gemini Models", "buckets": [
          {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 1,
           "resetTime": "2026-09-16T13:01:03Z"}]}]}}
        """.utf8)
        let limits = try parseAntigravityUsage(idle)
        XCTAssertEqual(limits[.session]?.percentUsed, 0)
        XCTAssertNil(limits[.session]?.resetsAt)
    }

    /// 묶음 차례는 서버가 정한다. 이름으로 골라야 뒤집혀도 맞는다.
    func test_picksGeminiEvenWhenSecond() throws {
        let flipped = Data("""
        {"response": {"groups": [
          {"displayName": "Claude and GPT models", "buckets": [
            {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.1}]},
          {"displayName": "Gemini Models", "buckets": [
            {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.9}]}]}}
        """.utf8)
        XCTAssertEqual(try parseAntigravityUsage(flipped)[.session]?.percentRemaining, 90)
    }

    /// 구글이 버킷 이름을 바꾸면 첫째 묶음으로 떨어진다. 빈 카드보다 낫다.
    func test_unknownBucketNamesFallBackToFirstGroup() throws {
        let renamed = Data("""
        {"response": {"groups": [
          {"displayName": "Native Models", "buckets": [
            {"bucketId": "native-5h", "window": "5h", "remainingFraction": 0.4}]},
          {"displayName": "Partner Models", "buckets": [
            {"bucketId": "partner-5h", "window": "5h", "remainingFraction": 0.9}]}]}}
        """.utf8)
        let limits = try parseAntigravityUsage(renamed)
        XCTAssertEqual(limits[.session]?.percentRemaining, 40)
        XCTAssertEqual(limits.count, 1)
    }

    /// 모르는 창 종류는 담을 칸이 없다. 그 버킷만 건너뛴다.
    func test_skipsUnknownWindow() throws {
        let odd = Data("""
        {"response": {"groups": [{"displayName": "Gemini Models", "buckets": [
          {"bucketId": "gemini-monthly", "window": "monthly", "remainingFraction": 0.5},
          {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.5}]}]}}
        """.utf8)
        let limits = try parseAntigravityUsage(odd)
        XCTAssertEqual(limits.count, 1)
        XCTAssertNotNil(limits[.session])
    }

    func test_emptyGroupsYieldNothing() throws {
        XCTAssertTrue(try parseAntigravityUsage(Data("""
        {"response": {"groups": []}}
        """.utf8)).isEmpty)
    }

    func test_rejectsNonObject() {
        XCTAssertThrowsError(try parseAntigravityUsage(Data("[]".utf8)))
    }

    // MARK: 플랜

    func test_readsPlanName() {
        XCTAssertEqual(parseAntigravityPlan(Data("""
        {"userStatus": {"name": "Suwon Chae", "planStatus": {"planInfo":
          {"teamsTier": "TEAMS_TIER_PRO", "planName": "Pro"}}}}
        """.utf8)), "Pro")
        XCTAssertNil(parseAntigravityPlan(Data("{}".utf8)))
    }

    // MARK: 접속 정보

    /// `ps -A -o pid=,command=` 한 줄에서 pid 와 CSRF 토큰을 캐낸다.
    let psOutput = """
      440 /usr/libexec/secinitd
      742 /Applications/Antigravity.app/Contents/MacOS/Antigravity
     2608 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --override_ide_name antigravity --subclient_type hub --override_ide_version 2.12.2 --https_server_port 0 --csrf_token 00000000-0000-4000-8000-000000000000 --app_data_dir antigravity --enable_sidecars
     2723 /Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app/Contents/MacOS/Antigravity Helper --type=renderer
    """

    func test_findsProcessAndToken() throws {
        let found = try XCTUnwrap(parseAntigravityProcesses(psOutput: psOutput).first)
        XCTAssertEqual(found.pid, 2608)
        XCTAssertEqual(found.token, "00000000-0000-4000-8000-000000000000")
    }

    /// 앱이 꺼져 있으면 그 줄이 없다. 헬퍼 프로세스만 보고 붙잡으면 안 된다.
    func test_noServerLineIsEmpty() {
        XCTAssertTrue(parseAntigravityProcesses(psOutput: """
          440 /usr/libexec/secinitd
          742 /Applications/Antigravity.app/Contents/MacOS/Antigravity
        """).isEmpty)
    }

    /// CLI 도 같은 이름의 서버를 띄운다. 앱 번들 안의 것만 잡는다.
    func test_ignoresCliLanguageServer() {
        XCTAssertTrue(parseAntigravityProcesses(psOutput: """
         3100 /Users/me/.gemini/antigravity-cli/bin/language_server --standalone --csrf_token abc
        """).isEmpty)
    }

    func test_tokenWithEqualsSign() throws {
        let found = try XCTUnwrap(parseAntigravityProcesses(psOutput: """
         2608 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token=abc-123 --standalone
        """).first)
        XCTAssertEqual(found.token, "abc-123")
    }

    /// 토큰 없이 도는 서버는 부를 수 없다. 반쯤 아는 상태로 넘기지 않는다.
    func test_serverWithoutTokenIsSkipped() {
        XCTAssertTrue(parseAntigravityProcesses(psOutput: """
         2608 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone
        """).isEmpty)
    }

    /// `lsof -nP -p <pid>` 에서 루프백 LISTEN 포트만. 큰 쪽이 평문 HTTP 라 먼저다.
    let lsofOutput = """
    language_ 2608 me    7u  IPv4 0xad7d730890093a7e  0t0  TCP 127.0.0.1:49271 (LISTEN)
    language_ 2608 me    8u  IPv4 0x6d91c0d130e953fb  0t0  TCP 127.0.0.1:49272 (LISTEN)
    language_ 2608 me   11u  IPv4 0x2c4159c3d7ca9905  0t0  TCP 10.61.56.32:55152->172.217.117.4:443 (ESTABLISHED)
    language_ 2608 me   38u  IPv4 0xb1062a5db9efc7a0  0t0  TCP 127.0.0.1:49271->127.0.0.1:49303 (ESTABLISHED)
    """

    func test_loopbackListenPortsLargestFirst() {
        XCTAssertEqual(parseLoopbackPorts(lsof: lsofOutput), [49272, 49271])
    }

    func test_ignoresNonLoopbackAndNonListen() {
        XCTAssertEqual(parseLoopbackPorts(lsof: """
        x 1 me 3u IPv4 0x1 0t0 TCP 10.0.0.2:8080 (LISTEN)
        x 1 me 4u IPv4 0x2 0t0 TCP 127.0.0.1:9000->127.0.0.1:1 (ESTABLISHED)
        """), [])
    }

    // MARK: 리더

    struct FakeProbe: AntigravityProbing {
        var endpointValue: AntigravityEndpoint?
        func endpoint() -> AntigravityEndpoint? { endpointValue }
    }

    struct FakeFetcher: AntigravityUsageFetching {
        var report: AntigravityReport?
        var error: UsageFetchError?
        /// 어느 포트로 왔는지 기록한다. 큰 쪽부터 도는지 보려면 필요하다.
        final class Log: @unchecked Sendable {
            var ports: [Int] = []
        }
        var log = Log()
        /// 이 포트로 온 요청만 성공시킨다. nil 이면 전부 성공이다.
        var onlyPort: Int?

        func report(port: Int, token: String) async throws -> AntigravityReport {
            log.ports.append(port)
            if let onlyPort, port != onlyPort {
                throw UsageFetchError(description: "HTTP 400 wrong port")
            }
            if let error { throw error }
            return report!
        }
    }

    private func installedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clf-ag-\(UUID().uuidString)/Antigravity.app", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    let endpoint = AntigravityEndpoint(ports: [49272, 49271], token: "t")

    func test_notInstalledIsEmpty() async {
        let reader = AntigravityReader(
            appPaths: [URL(fileURLWithPath: "/nope/Antigravity.app")],
            probe: FakeProbe(endpointValue: endpoint), session: FakeFetcher())
        XCTAssertFalse(reader.isInstalled)
        let result = await reader.read()
        XCTAssertEqual(result, .empty)
    }

    func test_readBuildsAntigravityOrg() async throws {
        let limits = try parseAntigravityUsage(pro)
        let reader = AntigravityReader(
            appPaths: [try installedDir()],
            probe: FakeProbe(endpointValue: endpoint),
            session: FakeFetcher(report: AntigravityReport(plan: "Pro", limits: limits)))
        let result = await reader.read()
        let org = try XCTUnwrap(result.orgs.first)
        XCTAssertEqual(org.uuid, AntigravityReader.accountID)
        XCTAssertEqual(org.name, "Antigravity")
        XCTAssertEqual(org.provider, .antigravity)
        XCTAssertEqual(org.plan, "Pro")
        XCTAssertFalse(org.isActive)
        XCTAssertEqual(org.rowKinds, [.session, .weeklyAll])
    }

    /// 앱이 꺼져 있으면 값이 없다. 값을 못 읽은 것과 앱이 꺼진 것은 다르고,
    /// 사용자가 할 일도 다르다.
    func test_appNotRunningSaysSo() async throws {
        let reader = AntigravityReader(
            appPaths: [try installedDir()],
            probe: FakeProbe(endpointValue: nil), session: FakeFetcher())
        let result = await reader.read()
        let org = try XCTUnwrap(result.orgs.first)
        XCTAssertFalse(org.hasUsage)
        XCTAssertEqual(org.error, AntigravityReader.offMessage)
        XCTAssertFalse(result.offline, "앱이 꺼진 것은 회선이 끊긴 것이 아니다")
        XCTAssertFalse(result.throttled)
    }

    /// 큰 포트가 평문이다. 그쪽이 먼저고, 틀리면 남은 포트로 넘어간다.
    func test_triesLargestPortFirstThenFallsBack() async throws {
        let fetcher = FakeFetcher(report: AntigravityReport(plan: nil, limits: [:]),
                                  onlyPort: 49271)
        let reader = AntigravityReader(appPaths: [try installedDir()],
                                       probe: FakeProbe(endpointValue: endpoint),
                                       session: fetcher)
        _ = await reader.read()
        XCTAssertEqual(fetcher.log.ports, [49272, 49271])
    }

    /// 끊김은 Claude, Codex 와 같은 갈래로 올라간다. ReadGate 가 한 자리에서 본다.
    func test_offlineSurfaces() async throws {
        let reader = AntigravityReader(appPaths: [try installedDir()],
                                       probe: FakeProbe(endpointValue: endpoint),
                                       session: FakeFetcher(error: .noNetwork))
        let result = await reader.read()
        XCTAssertTrue(result.offline)
        XCTAssertFalse(result.orgs.isEmpty, "카드는 남는다. 이유만 적는다")
    }

    // MARK: 화면 규칙

    func test_barCodeForAntigravity() {
        XCTAssertEqual(BarText.codes(for: ["NAVER_TEAM_40", "Codex", "Antigravity"]),
                       ["NAVER_TEAM_40": "T40", "Codex": "Co", "Antigravity": "An"])
    }

    func test_weeklyLabelHasNoScopeWord() {
        XCTAssertEqual(LimitKind.weeklyAll.label(for: .antigravity), "주간")
    }

    private func org(_ provider: Provider, stale: Bool) -> OrgUsage {
        OrgUsage(uuid: provider.rawValue, name: provider.rawValue, isActive: false, plan: nil,
                 provider: provider,
                 limits: [.session: UsageLimit(percentUsed: 10, resetsAt: nil, severity: "")],
                 error: stale ? "이유" : nil, isStale: stale)
    }

    /// 낡은 Antigravity 값은 다시 읽을 길이 없다. Claude 의 낡은 값은 회선이
    /// 돌아오면 몇 분 안에 스스로 고쳐진다.
    func test_onlyAntigravityFreezes() {
        XCTAssertTrue(org(.antigravity, stale: true).isFrozen)
        XCTAssertFalse(org(.antigravity, stale: false).isFrozen)
        XCTAssertFalse(org(.claude, stale: true).isFrozen)
        XCTAssertFalse(org(.codex, stale: true).isFrozen)
    }

    /// 갱신될 수 없는 숫자를 "지금" 을 말하는 자리에 두지 않는다.
    /// 팝오버와 설정 목록에는 그대로 남는다.
    func test_frozenOrgLeavesTheBar() {
        let prefs = DesktopPreferences()
        let frozen = org(.antigravity, stale: true)
        let live = org(.claude, stale: false)
        XCTAssertEqual(prefs.barOrgs(from: [live, frozen]).map(\.uuid), ["claude"])
        XCTAssertEqual(prefs.apply(to: [live, frozen]).count, 2)
    }

    /// 들어온 차례다. 기존 사용자의 화면이 위에서부터 그대로 유지된다.
    func test_defaultOrderIsClaudeCodexAntigravity() {
        let ag = org(.antigravity, stale: false)
        let codex = org(.codex, stale: false)
        let claude = org(.claude, stale: false)
        XCTAssertEqual(DesktopPreferences().apply(to: [ag, codex, claude]).map(\.provider),
                       [.claude, .codex, .antigravity])
    }

    /// 순서를 정했으면 그쪽이 이긴다. 공급자 차례는 기본값일 뿐이다.
    func test_explicitOrderBeatsProviderRank() {
        var prefs = DesktopPreferences()
        prefs.order = ["antigravity", "claude"]
        XCTAssertEqual(prefs.apply(to: [org(.claude, stale: false),
                                        org(.antigravity, stale: false)]).map(\.provider),
                       [.antigravity, .claude])
    }
}

/// 적대적 리뷰가 잡아낸 자리들. 전부 실제로 값이 틀어지는 경로다.
/// docs/design/19-antigravity-usage.md
final class AntigravityEdgeTests: XCTestCase {

    private func bucket(_ body: String) throws -> UsageLimit? {
        try parseAntigravityUsage(Data("""
        {"response": {"groups": [{"displayName": "Gemini Models", "buckets": [\(body)]}]}}
        """.utf8))[.session]
    }

    /// **protobuf JSON 은 기본값 필드를 안 싣는다.** 다 쓴 창은
    /// `remainingFraction` 이 통째로 빠진 채로 온다. 버킷을 건너뛰면 한도를
    /// 다 쓴 바로 그 순간에 카드가 옛 숫자를 내밀고 알림이 침묵한다.
    func test_missingFractionMeansFullyUsed() throws {
        let limit = try XCTUnwrap(bucket("""
        {"bucketId": "gemini-5h", "window": "5h", "resetTime": "2026-09-16T13:01:03Z"}
        """))
        XCTAssertEqual(limit.percentUsed, 100)
        XCTAssertEqual(limit.percentRemaining, 0)
        XCTAssertNotNil(limit.resetsAt, "소진된 창은 리셋 시각이 있어야 한다")
    }

    /// 조금이라도 썼으면 `창 안 열림` 이 아니다. 반올림한 정수로 판정하면
    /// 0.4% 쓴 창이 안 열린 창으로 둔갑한다.
    func test_barelyUsedWindowIsOpen() throws {
        let limit = try XCTUnwrap(bucket("""
        {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.996,
         "resetTime": "2026-09-16T13:01:03Z"}
        """))
        XCTAssertEqual(limit.percentUsed, 1, "0 으로 내리면 창 안 열림으로 읽힌다")
        XCTAssertNotNil(limit.resetsAt)
    }

    /// 조금이라도 남았으면 소진이 아니다. 반올림으로 100 을 만들면 아직 쓸 수
    /// 있는 계정에 소진 알림이 나간다.
    func test_barelyLeftIsNotExhausted() throws {
        let limit = try XCTUnwrap(bucket("""
        {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.004}
        """))
        XCTAssertEqual(limit.percentUsed, 99)
        XCTAssertGreaterThan(limit.percentRemaining, 0, "아직 쓸 수 있는데 소진이라 하면 안 된다")
    }

    /// 안 쓴 창만 리셋 시각을 버린다. 그 값이 `지금 + 창 길이` 라 흐르기 때문이다.
    func test_onlyUntouchedWindowDropsReset() throws {
        XCTAssertNil(try bucket("""
        {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 1,
         "resetTime": "2026-09-16T13:01:03Z"}
        """)?.resetsAt)
    }

    /// 부동소수 오차로 90% 가 89% 로 새면 안 된다.
    func test_roundingStaysHonestAcrossTheRange() throws {
        for (remaining, used) in [(0.9, 10), (0.85, 15), (0.5, 50), (0.38, 62), (0.1, 90)] {
            let limit = try XCTUnwrap(bucket("""
            {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": \(remaining)}
            """))
            XCTAssertEqual(limit.percentUsed, used, "잔여 \(remaining)")
        }
    }

    /// 앱이 비정상 종료하면 자식 서버가 고아로 남는다. 다음에 앱을 켜면 둘이
    /// 보이는데, 죽은 쪽을 고르면 카드가 `꺼져 있다` 로 굳고 `켜기` 를 눌러도
    /// 안 고쳐진다. 후보를 전부 내주고 부르는 쪽이 포트로 가린다.
    func test_listsAllServersNewestFirst() {
        let found = parseAntigravityProcesses(psOutput: """
         2608 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token old
         4100 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token new
        """)
        XCTAssertEqual(found.map { $0.pid }, [4100, 2608], "새 프로세스가 먼저다")
        XCTAssertEqual(found.first?.token, "new")
    }

    /// 실행 파일이 그 서버인 줄만 잡는다. 명령줄에 경로가 스쳐 간 줄은 아니다.
    func test_ignoresLinesThatOnlyMentionTheServer() {
        XCTAssertTrue(parseAntigravityProcesses(psOutput: """
         3200 /bin/sh -c /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token fake
        """).isEmpty)
    }

    /// 경로에 공백이 있어도 깨지지 않는다.
    func test_pathWithSpaces() {
        let found = parseAntigravityProcesses(psOutput: """
         2608 /Users/me/My Apps/Antigravity.app/Contents/Resources/bin/language_server --csrf_token abc
        """)
        XCTAssertEqual(found.first?.token, "abc")
    }

    /// 값이 빠진 `--csrf_token` 뒤의 다른 플래그를 토큰으로 삼으면 안 된다.
    func test_flagIsNotAToken() {
        XCTAssertTrue(parseAntigravityProcesses(psOutput: """
         2608 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token --standalone
        """).isEmpty)
    }

    /// 서버가 와일드카드로 묶어도 루프백으로 닿는다. 못 읽으면 앱이 도는데
    /// 꺼졌다고 적는 자리로 떨어진다.
    func test_acceptsWildcardAndIPv6Listen() {
        XCTAssertEqual(parseLoopbackPorts(lsof: "x 1 me 7u IPv4 0x1 0t0 TCP *:49272 (LISTEN)"),
                       [49272])
        XCTAssertEqual(parseLoopbackPorts(lsof: "x 1 me 7u IPv6 0x1 0t0 TCP [::1]:49271 (LISTEN)"),
                       [49271])
    }

    func test_toleratesTrailingWhitespace() {
        XCTAssertEqual(parseLoopbackPorts(lsof: "x 1 me 7u IPv4 0x1 0t0 TCP 127.0.0.1:49272 (LISTEN) \r"),
                       [49272])
    }

    /// 이름이 바뀌어 첫째 묶음으로 떨어질 때도 3p 주머니는 고르지 않는다.
    /// 다른 주머니 숫자에 `Gemini` 배지를 달아 내보내면 그냥 거짓말이다.
    func test_fallbackStillSkipsThirdPartyGroup() throws {
        let renamed = Data("""
        {"response": {"groups": [
          {"displayName": "Partner", "buckets": [
            {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.05}]},
          {"displayName": "Native", "buckets": [
            {"bucketId": "native-5h", "window": "5h", "remainingFraction": 0.6}]}]}}
        """.utf8)
        XCTAssertEqual(try parseAntigravityUsage(renamed)[.session]?.percentRemaining, 60)
    }

    /// 칸이 둘뿐인 공급자도 둘 다 소진이면 전부 소진이다. `LimitKind.allCases`
    /// 를 셋으로 전제하면 Codex 와 Antigravity 는 영원히 그 말을 못 듣는다.
    func test_allWindowsExhaustedForTwoSlotProvider() {
        let dead = UsageLimit(percentUsed: 100, resetsAt: nil, severity: "")
        let org = OrgUsage(uuid: "a", name: "Antigravity", isActive: false, plan: "Pro",
                           provider: .antigravity,
                           limits: [.session: dead, .weeklyAll: dead])
        let alerts = UsageAlerts.build(for: org)
        XCTAssertEqual(alerts.first?.title, "Antigravity 한도 전부 소진")
    }

    /// Claude 는 셋이 다 막혀야 전부 소진이다. 위 고침이 이쪽을 안 건드려야 한다.
    func test_claudeStillNeedsAllThree() {
        let dead = UsageLimit(percentUsed: 100, resetsAt: nil, severity: "")
        let org = OrgUsage(uuid: "a", name: "T40", isActive: true, plan: "team",
                           limits: [.session: dead, .weeklyAll: dead])
        XCTAssertEqual(UsageAlerts.build(for: org).first?.title, "T40 5시간 한도 소진")
    }
}

/// 2차 적대적 리뷰가 잡아낸 자리들.
final class AntigravitySecondPassTests: XCTestCase {

    private func limits(_ body: String) throws -> [LimitKind: UsageLimit] {
        try parseAntigravityUsage(Data("""
        {"response": {"groups": [{"displayName": "Gemini Models", "buckets": [\(body)]}]}}
        """.utf8))
    }

    /// **키가 없을 때만 0 이다.** 키가 있는데 못 읽는 값이면 건너뛴다. 못 읽은
    /// 값을 소진으로 읽으면 80% 남은 계정에 소리까지 붙은 소진 알림이 나간다.
    /// 줄이 사라지는 것은 사용자가 알아채지만 거짓 소진은 알아챌 방법이 없다.
    func test_unreadableFractionIsSkippedNotZero() throws {
        for value in ["\"0.8\"", "null", "{}"] {
            let parsed = try limits("""
            {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": \(value)}
            """)
            XCTAssertTrue(parsed.isEmpty, "못 읽는 값 \(value) 를 소진으로 읽으면 안 된다")
        }
    }

    /// 키가 아예 없는 것은 다르다. protobuf JSON 이 기본값을 안 실은 것이다.
    func test_absentFractionIsFullyUsed() throws {
        XCTAssertEqual(try limits("""
        {"bucketId": "gemini-5h", "window": "5h"}
        """)[.session]?.percentUsed, 100)
    }

    /// 칸 하나만 읽힌 것은 `전부` 를 말할 근거가 못 된다. 주간 버킷의 창
    /// 종류가 바뀌어 줄이 사라지면 5시간 한 칸이 전부가 되어 버린다.
    func test_singleParsedWindowDoesNotClaimEverything() {
        let dead = UsageLimit(percentUsed: 100, resetsAt: nil, severity: "")
        let org = OrgUsage(uuid: "a", name: "Antigravity", isActive: false, plan: "Pro",
                           provider: .antigravity, limits: [.session: dead])
        XCTAssertEqual(UsageAlerts.build(for: org).first?.title, "Antigravity 5시간 한도 소진")
    }

    /// 경로에 ` -` 가 든 앱은 **일부러** 못 알아본다. `ps` 가 argv 를 공백
    /// 하나로 이어 붙여서 `/apps -old/...` 와 `/bin/sh -c ...` 가 글자로 같은
    /// 모양이 된다. 둘 중 하나만 고를 수 있고, 아무 줄이나 서버로 믿는 쪽보다
    /// 못 알아보는 쪽이 낫다.
    func test_pathContainingDashSegmentIsGivenUp() {
        XCTAssertTrue(parseAntigravityProcesses(psOutput: """
         2608 /Users/me/apps -old/Antigravity.app/Contents/Resources/bin/language_server --csrf_token abc
        """).isEmpty)
    }

    /// 인자 사이 공백이 둘이어도 알아본다.
    func test_doubleSpacedArguments() {
        XCTAssertEqual(parseAntigravityProcesses(psOutput: """
         2608 /Applications/Antigravity.app/Contents/Resources/bin/language_server  --csrf_token   abc
        """).first?.token, "abc")
    }

    /// 토큰이 HTTP 헤더 값이 된다. 눈에 안 보이는 글자가 붙으면 안 된다.
    func test_tokenIsTrimmed() {
        XCTAssertEqual(parseAntigravityProcesses(psOutput:
            " 2608 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token abc\r"
        ).first?.token, "abc")
    }

    /// 묶음이 3p 하나뿐이면 그릴 것이 없다. 다른 주머니 숫자에 `Gemini` 배지를
    /// 달아 내보내느니 빈 카드가 낫다.
    func test_onlyThirdPartyGroupYieldsNothing() throws {
        XCTAssertTrue(try parseAntigravityUsage(Data("""
        {"response": {"groups": [{"displayName": "Claude and GPT models", "buckets": [
          {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.2}]}]}}
        """.utf8)).isEmpty)
    }

    /// 3p 판별이 첫 버킷 하나에만 걸려 있으면 차례가 뒤집힐 때 샌다.
    func test_thirdPartyDetectedFromAnyBucket() throws {
        XCTAssertTrue(try parseAntigravityUsage(Data("""
        {"response": {"groups": [{"displayName": "Partner", "buckets": [
          {"bucketId": "misc", "window": "monthly", "remainingFraction": 0.5},
          {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.2}]}]}}
        """.utf8)).isEmpty)
    }

    /// NaN 이 `Int` 변환에 닿으면 프로세스가 죽는다. 지금은 못 닿지만 이
    /// 함수에 다음 호출자가 생기는 순간 지뢰다.
    func test_usedPercentSurvivesNaN() {
        XCTAssertEqual(usedPercent(remaining: .nan), 100)
        XCTAssertEqual(usedPercent(remaining: .infinity), 0)
        XCTAssertEqual(usedPercent(remaining: -.infinity), 100)
    }

    /// 명령이 실패한 것과 출력이 원래 없는 것은 다르다. 같은 빈 문자열로
    /// 뭉뚱그리면 잘린 결과가 옳은 결과 행세를 한다.
    func test_shellTellsFailureFromEmptyOutput() {
        XCTAssertNil(Shell.run("/nope/nope", []))
        XCTAssertEqual(Shell.run("/usr/bin/true", []), "")
    }
}
