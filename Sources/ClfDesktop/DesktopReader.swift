import Foundation

/// 계정 하나의 현재 상태. UI 가 그대로 그린다.
public struct OrgUsage: Sendable, Equatable, Identifiable {
    public let uuid: String
    public let name: String
    public let isActive: Bool
    public let plan: String?
    public let limits: [LimitKind: UsageLimit]
    /// Enterprise 는 시간 창 대신 월 예산이 온다.
    public let spend: SpendUsage?
    /// 못 읽었으면 이유. `isStale` 이면 값이 있으면서 이유도 있다.
    public let error: String?
    /// 이번에 못 읽어서 지난번 값을 그대로 보여주는 중이다.
    public let isStale: Bool

    public var id: String { uuid }

    /// 보여줄 것이 하나라도 있나. 시간 창이든 월 예산이든.
    public var hasUsage: Bool { !limits.isEmpty || spend != nil }

    /// 셋 중 가장 좁은 창. 메뉴바가 한 계정을 한 숫자로 말해야 할 때 쓴다.
    public var binding: UsageLimit? {
        limits.values.min { $0.percentRemaining < $1.percentRemaining }
    }

    public init(uuid: String, name: String, isActive: Bool, plan: String?,
                limits: [LimitKind: UsageLimit], spend: SpendUsage? = nil,
                error: String? = nil, isStale: Bool = false) {
        self.uuid = uuid
        self.name = name
        self.isActive = isActive
        self.plan = plan
        self.limits = limits
        self.spend = spend
        self.error = error
        self.isStale = isStale
    }
}

public struct DesktopSnapshot: Sendable, Equatable {
    /// 사용량을 읽어낸 계정.
    public let orgs: [OrgUsage]
    /// 앱에서 한 번도 열지 않아 토큰이 없는 계정 이름. 없는 것을 숨기지 않는다.
    public let unreadable: [String]
    /// 그 계정들의 uuid. 설정에서 순서와 숨김을 걸려면 uuid 가 있어야 한다.
    public let unreadableByUUID: [String: String]
    /// 서버가 429 로 막았다. 실패와 다르다. 더 물어보면 안 된다는 뜻이다.
    public let throttled: Bool
    /// 이번에 알아낸 계정 이름. 다음 읽기가 캐시로 쓴다.
    public let names: [String: String]
    public let readAt: Date

    public init(orgs: [OrgUsage], unreadable: [String],
                unreadableByUUID: [String: String] = [:],
                throttled: Bool = false, names: [String: String] = [:], readAt: Date) {
        self.orgs = orgs
        self.unreadable = unreadable
        self.unreadableByUUID = unreadableByUUID
        self.throttled = throttled
        self.names = names
        self.readAt = readAt
    }

    public var active: OrgUsage? { orgs.first { $0.isActive } }

    /// 설정 화면이 보는 목록. 사용량을 못 읽는 계정도 들어간다.
    ///
    /// 사용자가 쓸 조합에 들어 있는데 목록에 없으면 순서도 못 정하고 미리
    /// 숨길 수도 없다. 사용량을 모르는 것과 계정을 모르는 것은 다르다.
    public var knownOrgs: [OrgUsage] {
        orgs + unreadableByUUID.map { uuid, name in
            OrgUsage(uuid: uuid, name: name, isActive: false, plan: nil, limits: [:],
                     error: "앱에서 이 계정을 한 번 열면 사용량이 읽힌다")
        }.sorted { $0.name < $1.name }
    }
}

/// Claude 데스크톱 앱의 상태를 읽는다.
///
/// **읽기만 한다.** 앱의 파일을 고치지 않고, 추론 요청도 보내지 않는다.
/// 토큰 갱신은 앱이 하게 두고 만료되면 그 사실만 말한다.
/// docs/design/10-desktop-usage.md
public struct DesktopReader: Sendable {
    public static let defaultSupportDirectory =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)

    private let support: URL
    private let session: any UsageFetching

    public init(supportDirectory: URL = DesktopReader.defaultSupportDirectory,
                session: any UsageFetching = LiveUsageFetcher()) {
        self.support = supportDirectory
        self.session = session
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: support.appendingPathComponent("config.json").path)
    }

    /// `names` 를 주면 계정 목록을 다시 묻지 않는다. 이름은 안 바뀌는데
    /// 매번 물으면 읽기당 요청이 하나씩 더 나간다.
    public func read(now: Date = Date(),
                     names cached: [String: String] = [:]) async throws -> DesktopSnapshot {
        let key = try safeStorageKeyFromKeychain()
        let tokens = try parseTokenCache(
            try decryptConfigValue(key: key, keys: ["oauth:tokenCacheV2", "oauth:tokenCache"]))
        let current = try? activeOrg(key: key)
        let names = cached.isEmpty
            ? ((try? await session.orgNames(sessionKey: sessionKey(key: key))) ?? [:])
            : cached

        var orgs: [OrgUsage] = []
        var throttled = false
        for (uuid, token) in tokens {
            let name = names[uuid] ?? String(uuid.prefix(8))
            guard token.canReadUsage else {
                orgs.append(OrgUsage(uuid: uuid, name: name, isActive: uuid == current,
                                     plan: token.subscriptionType, limits: [:],
                                     error: "이 토큰에는 user:profile 스코프가 없다"))
                continue
            }
            do {
                let report = try await session.usage(token: token.token)
                orgs.append(OrgUsage(uuid: uuid, name: name, isActive: uuid == current,
                                     plan: token.subscriptionType,
                                     limits: report.limits, spend: report.spend))
            } catch {
                if (error as? UsageFetchError)?.throttled == true { throttled = true }
                orgs.append(OrgUsage(uuid: uuid, name: name, isActive: uuid == current,
                                     plan: token.subscriptionType, limits: [:],
                                     error: "\(error)"))
            }
        }
        // 활성 계정을 맨 위에. 나머지는 이름순
        orgs.sort { ($0.isActive ? 0 : 1, $0.name) < ($1.isActive ? 0 : 1, $1.name) }

        let missing = names.filter { tokens[$0.key] == nil }
        return DesktopSnapshot(orgs: orgs,
                               unreadable: missing.values.sorted(),
                               unreadableByUUID: missing,
                               throttled: throttled,
                               names: names,
                               readAt: now)
    }

    // MARK: 파일에서 읽기

    private func decryptConfigValue(key: Data, keys: [String]) throws -> Data {
        let path = support.appendingPathComponent("config.json")
        guard let data = FileManager.default.contents(atPath: path.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw SafeStorageError(description: "config.json 을 읽지 못했다") }

        for name in keys {
            guard let encoded = root[name] as? String,
                  let blob = Data(base64Encoded: encoded) else { continue }
            return try decryptV10(blob, key: key)
        }
        throw SafeStorageError(description: "config.json 에 oauth 토큰 캐시가 없다")
    }

    /// 지금 앱이 쓰는 계정. **로컬 파일만 읽는다.** 네트워크를 안 타므로
    /// 자주 물어도 된다. 사용량과 달리 이건 공짜다.
    public func activeOrgUUID() -> String? {
        guard let key = try? safeStorageKeyFromKeychain() else { return nil }
        return try? activeOrg(key: key)
    }

    private func activeOrg(key: Data) throws -> String {
        String(decoding: stripDomainHash(try cookie("lastActiveOrg", key: key)), as: UTF8.self)
    }

    private func sessionKey(key: Data) throws -> String {
        String(decoding: stripDomainHash(try cookie("sessionKey", key: key)), as: UTF8.self)
    }

    /// 앱이 쥐고 있는 파일을 직접 열지 않는다. 사본을 만들어 읽는다.
    private func cookie(_ name: String, key: Data) throws -> Data {
        let source = support.appendingPathComponent("Cookies")
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("clf-cookies-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        guard let blob = try readCookieBlob(from: copy, name: name) else {
            throw SafeStorageError(description: "\(name) 쿠키가 없다")
        }
        return try decryptV10(blob, key: key)
    }
}
