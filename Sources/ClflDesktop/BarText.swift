import Foundation

/// 메뉴바 막대에 들어갈 글자.
///
/// 막대는 다른 앱과 자리를 나눠 쓴다. 조직 이름을 그대로 넣으면 화면 절반을
/// 먹는다. 팝오버에는 전체 이름이 나오므로 여기서는 구별만 되면 된다.
public enum BarText {
    public static let placeholder = "clfl"
    /// 사용량을 못 읽은 조직. 0% 로 그리면 한도가 찬 것처럼 보인다.
    public static let unknown = "?"

    /// 조직 이름을 세 글자 안팎으로 줄인다.
    ///
    /// 숫자로 끝나면 앞 낱말의 첫 글자를 붙인다. `NAVER_TEAM_40` 은 `T40` 이다.
    /// 한 계정이 쓰는 조직들은 접두사가 같은 경우가 많아 뒤쪽이 구별에 쓸모 있다.
    public static func short(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        guard let last = words.last else { return unknown }

        if last.allSatisfy(\.isNumber) {
            guard words.count >= 2, let initial = words[words.count - 2].first else {
                return String(last)
            }
            return initial.uppercased() + last
        }
        return String(last.prefix(3)).capitalizedFirst
    }

    /// 조직이 하나면 이름을 안 붙인다. 어느 조직인지는 이미 안다.
    public static func label(for orgs: [OrgUsage]) -> String {
        guard !orgs.isEmpty else { return placeholder }
        if orgs.count == 1 { return percent(orgs[0]) }
        return orgs.map { "\(short($0.name)) \(percent($0))" }.joined(separator: "  ")
    }

    /// 리셋까지 남은 시간을 사람이 읽는 말로.
    ///
    /// 단위를 두 개까지만 쓴다. `5일 5시간 30분` 은 정확하지만 아무도 그렇게
    /// 안 말하고, 며칠 남은 창에서 분은 잡음이다.
    public static func until(_ date: Date?, from now: Date = Date()) -> String {
        // 사용률 0 인 창은 리셋 시각이 없다. `-` 로 얼버무리지 않는다
        guard let date else { return "창 안 열림" }
        let left = date.timeIntervalSince(now)
        guard left > 0 else { return "지남" }

        let days = Int(left / 86400)
        let hours = Int(left.truncatingRemainder(dividingBy: 86400) / 3600)
        let minutes = Int(left.truncatingRemainder(dividingBy: 3600) / 60)

        if days > 0 { return hours > 0 ? "\(days)일 \(hours)시간 뒤" : "\(days)일 뒤" }
        if hours > 0 { return minutes > 0 ? "\(hours)시간 \(minutes)분 뒤" : "\(hours)시간 뒤" }
        // "0시간 12분" 은 사람이 안 쓰는 말이다
        return minutes > 0 ? "\(minutes)분 뒤" : "곧"
    }

    /// 가장 좁은 창을 쓴다. 5시간이 널널해도 주간이 바닥이면 바닥이 사실이다.
    private static func percent(_ org: OrgUsage) -> String {
        guard let binding = org.binding else { return unknown }
        return "\(binding.percentRemaining)%"
    }
}

private extension String {
    /// 나머지는 건드리지 않는다. `ID` 를 `Id` 로 바꾸면 안 된다.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
