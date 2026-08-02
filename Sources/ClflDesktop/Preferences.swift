import Foundation
import ClflStore

/// 어느 계정을 메뉴바에 보여줄지, 어떤 순서로 보여줄지.
///
/// 사람마다 조합이 다르다. 팀 둘에 Enterprise 하나, 팀 하나에 Enterprise 하나,
/// Enterprise 만. 그래서 목록을 고정하지 않고 사용자가 정하게 한다.
///
/// **보여줄 것을 담지 않고 숨길 것을 담는다.** 그래야 계정이 새로 생겼을 때
/// 자동으로 보인다. 보여줄 목록만 저장하면 새 계정이 설정을 열기 전까지
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

/// 게이지 퍼센트를 어느 쪽에서 읽을지.
///
/// 서버는 사용률을 준다. 남은 용량은 100 에서 0 으로 줄고 사용률은 0 에서
/// 100 으로 는다. 숫자와 채움이 함께 뒤집히고, 색 등급은 두 방식 모두
/// 잔여 기준 그대로다. docs/design/gauge-direction-mockup.html
public enum GaugeDirection: String, Codable, Sendable, CaseIterable {
    /// 남은 용량. 지금까지의 방식이라 기본값이다
    case remaining = "remaining"
    /// 사용률. 쓴 만큼 차오른다
    case used = "used"

    public var label: String {
        switch self {
        case .remaining: return "남은 용량"
        case .used:      return "사용률"
        }
    }

    /// 화면에 적을 숫자. 서버가 주는 사용률에서 방향에 맞게 고른다.
    public func displayPercent(used: Int) -> Int {
        self == .used ? used : 100 - used
    }

    /// 눈금 게이지가 켤 칸 수.
    ///
    /// 남은 용량은 **올림**이다. 1% 라도 남았으면 한 칸을 켠다. 사용률은
    /// **내림**이다. 1% 라도 남았으면 빈 칸 하나를 남긴다. 방향이 달라도
    /// "남은 것을 숨기지 않는다" 는 같은 규칙이라 두 방식의 켠 칸과
    /// 빈 칸이 정확히 맞물린다.
    public func litSteps(used: Int, total: Int) -> Int {
        let percent = displayPercent(used: used)
        guard percent > 0 else { return 0 }
        let raw = Double(percent) * Double(total) / 100
        let count = self == .used ? raw.rounded(.down) : raw.rounded(.up)
        return min(total, Int(count))
    }
}

/// 메뉴바 막대에 무엇을 그릴지.
/// 막대에 어느 계정을 올릴지 정하는 두 갈래.
///
/// 하나는 **지금 창이 떠 있는가**를 보고, 하나는 **사용자가 설정에서 골랐는가**
/// 를 본다. 기준이 아예 다르므로 한쪽이 다른 쪽의 부분집합이 아니다. 창이
/// 열린 계정을 설정에서 꺼 뒀어도 첫째 항목에는 나온다.
public enum BarContent: String, Codable, Sendable, CaseIterable {
    /// 지금 창이 떠 있는 계정. 기본 창이 쓰는 계정과 우리가 띄운 별도 창들.
    case windowed
    /// 설정 목록에서 켜 둔 계정 전부.
    case chosen

    public var label: String {
        switch self {
        case .windowed: return "창이 열려있는 계정만"
        case .chosen:   return "설정에서 지정한 계정"
        }
    }

    /// 무엇을 보고 고르는지 한 줄로. 설정 화면이 이 말을 옆에 붙인다.
    public var detail: String {
        switch self {
        case .windowed: return "기본 창과 우리가 띄운 창을 따라간다"
        case .chosen:   return "아래 목록에서 켠 계정을 그대로 그린다"
        }
    }

    /// 계정 목록 밑에 붙는 한 줄.
    ///
    /// 목록이 막대를 정하는지 아닌지가 고른 칸에 따라 다르다. `창이 열려있는
    /// 계정만` 은 숨김 목록을 안 보므로, 제목만 보고 목록을 껐다가 막대가
    /// 그대로라 어리둥절해지는 것을 막는다.
    public var listNote: String {
        switch self {
        case .windowed: return "지금은 창을 보고 정하므로 이 목록은 팝오버와 차례에만 쓰인다"
        case .chosen:   return "끈 계정은 팝오버에서도 빠진다"
        }
    }

    /// 옛 파일에는 `active_only` / `all_visible` 로 적혀 있다. 이름을 바꿨다고
    /// 설정이 초기화되면 안 된다.
    public init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "chosen", "all_visible": self = .chosen
        default:                      self = .windowed
        }
    }
}

public struct DesktopPreferences: Codable, Sendable, Equatable {
    public var version: Int
    /// 사용자가 명시적으로 끈 계정.
    public var hidden: Set<String>
    /// 사용자가 정한 순서. 여기 없는 계정은 뒤에 붙는다.
    public var order: [String]
    /// 막대에 그릴 범위. 팝오버는 이것과 무관하게 보이는 계정을 전부 보여준다.
    public var barContent: BarContent
    /// 막대를 얼마나 자세히 그릴지.
    public var barDetail: BarDetail
    /// 게이지 퍼센트의 방향. 팝오버와 막대가 같이 따른다.
    public var gaugeDirection: GaugeDirection

    public init(version: Int = 1, hidden: Set<String> = [], order: [String] = [],
                barContent: BarContent = .windowed, barDetail: BarDetail = .full,
                gaugeDirection: GaugeDirection = .remaining) {
        self.version = version
        self.hidden = hidden
        self.order = order
        self.barContent = barContent
        self.barDetail = barDetail
        self.gaugeDirection = gaugeDirection
    }

    /// 필드가 빠진 옛 파일도 읽는다. 설정이 안 열리는 것보다 낫다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        barContent = try c.decodeIfPresent(BarContent.self, forKey: .barContent) ?? .windowed
        barDetail = try c.decodeIfPresent(BarDetail.self, forKey: .barDetail) ?? .full
        gaugeDirection = try c.decodeIfPresent(GaugeDirection.self, forKey: .gaugeDirection) ?? .remaining
    }

    public func isHidden(_ uuid: String) -> Bool { hidden.contains(uuid) }

    public mutating func setHidden(_ uuid: String, _ value: Bool) {
        if value { hidden.insert(uuid) } else { hidden.remove(uuid) }
    }

    /// 숨긴 것을 걸러내고 순서를 매긴다.
    ///
    /// 순서를 안 정했으면 활성 계정이 먼저, 나머지는 이름순이다. 정했으면
    /// 그쪽이 이긴다. 활성 계정 우선은 기본값일 뿐 사용자 의사를 덮지 않는다.
    public func apply(to orgs: [OrgUsage]) -> [OrgUsage] {
        ordered(orgs.filter { !hidden.contains($0.uuid) })
    }

    /// 차례만 매긴다. 숨긴 목록은 안 본다.
    func ordered(_ orgs: [OrgUsage]) -> [OrgUsage] {
        guard !order.isEmpty else {
            return orgs.sorted { ($0.isActive ? 0 : 1, $0.name) < ($1.isActive ? 0 : 1, $1.name) }
        }
        // 순서에 있는 것부터, 없는 것은 뒤에 이름순으로. 사라진 계정 항목은 무시된다
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return orgs.sorted {
            let a = rank[$0.uuid] ?? Int.max
            let b = rank[$1.uuid] ?? Int.max
            return a == b ? $0.name < $1.name : a < b
        }
    }

    /// 막대에 그릴 계정. 팝오버에는 `apply(to:)` 결과를 전부 쓴다.
    ///
    /// `withWindow` 는 우리가 띄운 별도 창이 붙어 있는 계정의 uuid 다. 기본
    /// 창이 쓰는 계정은 `isActive` 로 알 수 있어 따로 넘기지 않는다.
    ///
    /// **사용량을 모르는 계정은 안 올린다.** `?` 와 빈 게이지는 자리만 먹고
    /// 알려주는 것이 없다. 팝오버와 설정에는 그대로 남는다. 거기서는 왜 못
    /// 읽는지까지 말할 수 있다.
    public func barOrgs(from orgs: [OrgUsage], withWindow: Set<String> = []) -> [OrgUsage] {
        let readable = orgs.filter(\.hasUsage)
        guard barContent == .windowed else { return apply(to: readable) }

        // 창을 보는 항목이므로 숨긴 목록은 안 본다. 두 항목의 기준이 다르다
        let open = ordered(readable.filter { $0.isActive || withWindow.contains($0.uuid) })
        guard open.isEmpty else { return open }
        // 창이 하나도 없으면 막대가 빈다. 빈 막대보다는 보이는 것 중 첫째를 쓴다
        return Array(apply(to: readable).prefix(1))
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
