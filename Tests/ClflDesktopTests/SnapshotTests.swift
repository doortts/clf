import XCTest
@testable import ClflDesktop

private func limit(_ used: Int) -> UsageLimit {
    UsageLimit(percentUsed: used, resetsAt: nil, severity: "normal")
}

/// 조직 하나를 한 숫자로 말해야 할 때의 규칙.
final class OrgUsageTests: XCTestCase {

    /// 셋 중 가장 좁은 창이 그 조직의 여유를 결정한다. 5시간이 넉넉해도
    /// 주간이 바닥이면 곧 막힌다.
    func test_bindingIsTheNarrowestWindow() {
        let org = OrgUsage(uuid: "u", name: "n", isActive: true, plan: "team",
                           limits: [.session: limit(20),
                                    .weeklyAll: limit(85),
                                    .weeklyScoped: limit(40)])
        XCTAssertEqual(org.binding?.percentRemaining, 15, "주간 전체가 가장 좁다")
    }

    func test_bindingNilWhenNothingRead() {
        let org = OrgUsage(uuid: "u", name: "n", isActive: false, plan: nil,
                           limits: [:], error: "토큰 만료")
        XCTAssertNil(org.binding)
    }

    func test_activePicksTheRightOrg() {
        let snapshot = DesktopSnapshot(orgs: [
            OrgUsage(uuid: "a", name: "A", isActive: false, plan: nil, limits: [:]),
            OrgUsage(uuid: "b", name: "B", isActive: true, plan: nil, limits: [:]),
        ], unreadable: [], readAt: Date())
        XCTAssertEqual(snapshot.active?.uuid, "b")
    }
}

/// 정해진 답을 내는 가짜 네트워크.
final class StubFetcher: UsageFetching, @unchecked Sendable {
    var usageByToken: [String: [LimitKind: UsageLimit]] = [:]
    var spendByToken: [String: SpendUsage] = [:]
    var failFor: Set<String> = []
    var names: [String: String] = [:]

    func usage(token: String) async throws -> UsageReport {
        if failFor.contains(token) {
            throw UsageFetchError(description: "토큰 만료. 앱에서 이 조직을 한 번 열면 갱신된다")
        }
        return UsageReport(limits: usageByToken[token] ?? [:], spend: spendByToken[token])
    }
    func orgNames(sessionKey: String) async throws -> [String: String] { names }
}

/// 조립 규칙. 파일과 Keychain 은 건드리지 않고 순수 조합만 본다.
final class SnapshotAssemblyTests: XCTestCase {

    func assemble(tokens: [String: DesktopToken], active: String?,
                  fetcher: StubFetcher) async -> DesktopSnapshot {
        var orgs: [OrgUsage] = []
        for (uuid, token) in tokens {
            let name = fetcher.names[uuid] ?? String(uuid.prefix(8))
            guard token.canReadUsage else {
                orgs.append(OrgUsage(uuid: uuid, name: name, isActive: uuid == active,
                                     plan: token.subscriptionType, limits: [:],
                                     error: "이 토큰에는 user:profile 스코프가 없다"))
                continue
            }
            do {
                let report = try await fetcher.usage(token: token.token)
                orgs.append(OrgUsage(uuid: uuid, name: name, isActive: uuid == active,
                                     plan: token.subscriptionType,
                                     limits: report.limits, spend: report.spend))
            } catch {
                orgs.append(OrgUsage(uuid: uuid, name: name, isActive: uuid == active,
                                     plan: token.subscriptionType, limits: [:],
                                     error: "\(error)"))
            }
        }
        orgs.sort { ($0.isActive ? 0 : 1, $0.name) < ($1.isActive ? 0 : 1, $1.name) }
        let unreadable = fetcher.names.filter { tokens[$0.key] == nil }.values.sorted()
        return DesktopSnapshot(orgs: orgs, unreadable: Array(unreadable), readAt: Date())
    }

    func token(_ value: String, profile: Bool = true) -> DesktopToken {
        DesktopToken(token: value, subscriptionType: "team", rateLimitTier: "t",
                     expiresAt: nil, canReadUsage: profile)
    }

    /// 활성 조직이 맨 위에 온다. 메뉴바가 첫 줄을 그것으로 그린다.
    func test_activeOrgComesFirst() async {
        let fetcher = StubFetcher()
        fetcher.names = ["a": "Zebra", "b": "Alpha"]
        let snapshot = await assemble(tokens: ["a": token("ta"), "b": token("tb")],
                                      active: "a", fetcher: fetcher)
        XCTAssertEqual(snapshot.orgs.map(\.name), ["Zebra", "Alpha"])
    }

    func test_inactiveOrgsSortedByName() async {
        let fetcher = StubFetcher()
        fetcher.names = ["a": "Zebra", "b": "Alpha", "c": "Middle"]
        let snapshot = await assemble(
            tokens: ["a": token("ta"), "b": token("tb"), "c": token("tc")],
            active: nil, fetcher: fetcher)
        XCTAssertEqual(snapshot.orgs.map(\.name), ["Alpha", "Middle", "Zebra"])
    }

    /// 한 조직이 실패해도 나머지는 보여야 한다. 전부 날리면 안 된다.
    func test_oneFailureDoesNotSinkTheRest() async {
        let fetcher = StubFetcher()
        fetcher.names = ["a": "A", "b": "B"]
        fetcher.failFor = ["ta"]
        fetcher.usageByToken = ["tb": [.session: limit(30)]]

        let snapshot = await assemble(tokens: ["a": token("ta"), "b": token("tb")],
                                      active: nil, fetcher: fetcher)
        let a = snapshot.orgs.first { $0.name == "A" }
        let b = snapshot.orgs.first { $0.name == "B" }
        XCTAssertNotNil(a?.error)
        XCTAssertTrue(a!.limits.isEmpty)
        XCTAssertEqual(b?.limits[.session]?.percentRemaining, 70)
        XCTAssertNil(b?.error)
    }

    /// user:profile 이 없으면 부르지도 않는다. 401 을 맞아볼 이유가 없다.
    func test_skipsTokensWithoutProfileScope() async {
        let fetcher = StubFetcher()
        fetcher.names = ["a": "A"]
        let snapshot = await assemble(tokens: ["a": token("ta", profile: false)],
                                      active: nil, fetcher: fetcher)
        XCTAssertTrue(snapshot.orgs[0].error?.contains("user:profile") ?? false)
    }

    /// 앱에서 한 번도 열지 않은 조직은 이름만 알고 사용량을 모른다.
    /// 목록에서 빼지 않고 못 읽는다고 말한다.
    func test_reportsOrgsWithoutTokens() async {
        let fetcher = StubFetcher()
        fetcher.names = ["a": "A", "gone": "Naver"]
        let snapshot = await assemble(tokens: ["a": token("ta")], active: "a", fetcher: fetcher)
        XCTAssertEqual(snapshot.unreadable, ["Naver"])
        XCTAssertEqual(snapshot.orgs.count, 1)
    }

    /// 이름을 못 얻어도 uuid 앞자리로 뭔가는 보여준다.
    func test_fallsBackToUuidPrefixWhenNameUnknown() async {
        let snapshot = await assemble(tokens: ["746e81ae-c1e7": token("t")],
                                      active: nil, fetcher: StubFetcher())
        XCTAssertEqual(snapshot.orgs[0].name, "746e81ae")
    }
}
