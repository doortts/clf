import Foundation
import ClflStore

/// 어느 조직을 메뉴바에 보여줄지, 어떤 순서로 보여줄지.
///
/// 사람마다 조합이 다르다. 팀 둘에 Enterprise 하나, 팀 하나에 Enterprise 하나,
/// Enterprise 만. 그래서 목록을 고정하지 않고 사용자가 정하게 한다.
///
/// **보여줄 것을 담지 않고 숨길 것을 담는다.** 그래야 조직이 새로 생겼을 때
/// 자동으로 보인다. 보여줄 목록만 저장하면 새 조직이 설정을 열기 전까지
/// 영영 안 보인다.
/// 막대를 얼마나 자세히 그릴지.
///
/// docs/design/ui-spec.html "표시 모드는 하나만 고른다". 폭과 정보량은 맞바꿀
/// 수밖에 없어서 노브를 여러 개 두지 않고 미리 맞춰둔 넷 중 하나를 고르게 한다.
public enum BarDetail: String, Codable, Sendable, CaseIterable {
    /// 코드, 숫자 두 줄, 도트 블록 세 줄
    case full = "full"
    /// 코드와 블록. 세 창을 그대로 보여주면서 폭은 절반 아래로
    case dots = "dots"
    /// 코드와 숫자 두 줄
    case numbers = "numbers"
    /// 코드 하나. 자세한 값은 눌러서 본다
    case code = "code"

    public var label: String {
        switch self {
        case .full:    return "기본"
        case .dots:    return "도트만"
        case .numbers: return "숫자만"
        case .code:    return "코드만"
        }
    }

    public var showsCode: Bool { true }
    public var showsNumbers: Bool { self == .full || self == .numbers }
    public var showsDots: Bool { self == .full || self == .dots }
}

/// 메뉴바 막대에 무엇을 그릴지.
public enum BarContent: String, Codable, Sendable, CaseIterable {
    /// 활성 조직 하나만. 조직이 셋이면 막대가 너무 길어진다
    case activeOnly = "active_only"
    /// 보이기로 한 조직 전부
    case allVisible = "all_visible"

    public var label: String {
        switch self {
        case .activeOnly: return "활성 조직만"
        case .allVisible: return "보이는 조직 전부"
        }
    }
}

public struct DesktopPreferences: Codable, Sendable, Equatable {
    public var version: Int
    /// 사용자가 명시적으로 끈 조직.
    public var hidden: Set<String>
    /// 사용자가 정한 순서. 여기 없는 조직은 뒤에 붙는다.
    public var order: [String]
    /// 막대에 그릴 범위. 팝오버는 이것과 무관하게 보이는 조직을 전부 보여준다.
    public var barContent: BarContent
    /// 막대를 얼마나 자세히 그릴지.
    public var barDetail: BarDetail

    public init(version: Int = 1, hidden: Set<String> = [], order: [String] = [],
                barContent: BarContent = .activeOnly, barDetail: BarDetail = .full) {
        self.version = version
        self.hidden = hidden
        self.order = order
        self.barContent = barContent
        self.barDetail = barDetail
    }

    /// 필드가 빠진 옛 파일도 읽는다. 설정이 안 열리는 것보다 낫다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        barContent = try c.decodeIfPresent(BarContent.self, forKey: .barContent) ?? .activeOnly
        barDetail = try c.decodeIfPresent(BarDetail.self, forKey: .barDetail) ?? .full
    }

    public func isHidden(_ uuid: String) -> Bool { hidden.contains(uuid) }

    public mutating func setHidden(_ uuid: String, _ value: Bool) {
        if value { hidden.insert(uuid) } else { hidden.remove(uuid) }
    }

    /// 숨긴 것을 걸러내고 순서를 매긴다.
    ///
    /// 순서를 안 정했으면 활성 조직이 먼저, 나머지는 이름순이다. 정했으면
    /// 그쪽이 이긴다. 활성 조직 우선은 기본값일 뿐 사용자 의사를 덮지 않는다.
    public func apply(to orgs: [OrgUsage]) -> [OrgUsage] {
        let shown = orgs.filter { !hidden.contains($0.uuid) }
        guard !order.isEmpty else {
            return shown.sorted { ($0.isActive ? 0 : 1, $0.name) < ($1.isActive ? 0 : 1, $1.name) }
        }
        // 순서에 있는 것부터, 없는 것은 뒤에 이름순으로. 사라진 조직 항목은 무시된다
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return shown.sorted {
            let a = rank[$0.uuid] ?? Int.max
            let b = rank[$1.uuid] ?? Int.max
            return a == b ? $0.name < $1.name : a < b
        }
    }

    /// 막대에 그릴 조직. 팝오버에는 `apply(to:)` 결과를 전부 쓴다.
    ///
    /// 숨긴 조직은 여기에도 안 나온다. 설정이 두 곳에 따로 있으면 헷갈린다.
    public func barOrgs(from orgs: [OrgUsage]) -> [OrgUsage] {
        let shown = apply(to: orgs)
        guard barContent == .activeOnly else { return shown }
        // 활성 조직을 숨겨뒀거나 활성이 없으면 막대가 빈다. 빈 막대보다는 첫째를 쓴다
        if let active = shown.first(where: \.isActive) { return [active] }
        return Array(shown.prefix(1))
    }
}

/// `~/Library/Application Support/clfl/desktop.json`
///
/// 우리 설정이므로 우리 디렉토리에 둔다. 데스크톱 앱의 파일은 읽기만 하고
/// 절대 쓰지 않는다.
public struct DesktopPreferencesFile: Sendable {
    private let url: URL

    public init(directory: URL? = nil) throws {
        let base = try directory ?? appSupportDirectory()
        self.url = base.appendingPathComponent("desktop.json")
    }

    /// 없거나 깨졌으면 기본값으로 시작한다. 설정 파일 하나 때문에 메뉴바가
    /// 안 뜨면 안 된다.
    public func load() -> DesktopPreferences {
        guard let data = FileManager.default.contents(atPath: url.path),
              let prefs = try? JSONDecoder().decode(DesktopPreferences.self, from: data)
        else { return DesktopPreferences() }
        return prefs
    }

    public func save(_ prefs: DesktopPreferences) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicWrite(try encoder.encode(prefs), to: url)
    }
}
