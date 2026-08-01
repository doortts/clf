import Foundation

/// 메뉴바 막대에 들어갈 글자.
///
/// 막대는 다른 앱과 자리를 나눠 쓴다. 조직 이름을 그대로 넣으면 화면 절반을
/// 먹는다. 팝오버에는 전체 이름이 나오므로 여기서는 구별만 되면 된다.
public enum BarText {
    public static let placeholder = "clfl"
    /// 사용량을 못 읽은 조직. 0% 로 그리면 한도가 찬 것처럼 보인다.
    public static let unknown = "?"

    /// 조직 이름을 두세 글자로 줄인다.
    ///
    /// docs/design/ui-spec.html "조직 이름 대신 두 글자 코드를 쓴다".
    /// 코드는 **집합에 딸린 값**이다. 겹치는지 알아야 정할 수 있어서 이름 하나만
    /// 보고는 못 만든다.
    ///
    /// | 이름 | 코드 | 규칙 |
    /// |---|---|---|
    /// | `NAVER_TEAM_40` | `T40` | 끝 숫자와 앞 낱말 첫 글자 |
    /// | `team1` | `T1` | 낱말과 숫자가 붙어 있어도 가른다 |
    /// | `Naver` | `Na` | 숫자가 없으면 앞 두 글자 |
    /// | `Naver` + `Nasdaq` | `N1` `N2` | 겹치면 첫 글자에 알파벳순 순번 |
    ///
    /// 시안은 `team` 이 든 이름에 알파벳순 번호를 붙이라고 했다. 이름이 이미
    /// 번호를 달고 있으면 그쪽을 쓴다. 앱 드롭다운에서 보는 것과 같아야 한다.
    public static func codes(for names: [String]) -> [String: String] {
        var draft: [String: String] = [:]
        for name in names { draft[name] = base(name) }

        // 겹치는 것만 첫 글자 + 알파벳순 순번으로 바꾼다. 순번이 목록 차례를
        // 따르면 조직이 늘고 줄 때마다 코드가 흔들려 눈이 못 따라간다
        var byCode: [String: [String]] = [:]
        for (name, code) in draft { byCode[code, default: []].append(name) }
        for (_, clashing) in byCode where clashing.count > 1 {
            for (i, name) in clashing.sorted().enumerated() {
                let initial = name.first.map { String($0).uppercased() } ?? unknown
                draft[name] = initial + String(i + 1)
            }
        }
        return draft
    }

    /// 겹침을 따지기 전의 1차 코드.
    static func base(_ name: String) -> String {
        let words = split(name)
        guard let last = words.last else { return unknown }
        if last.allSatisfy(\.isNumber) {
            guard words.count >= 2, let initial = words[words.count - 2].first else {
                return String(last)
            }
            return initial.uppercased() + last
        }
        return String(last.prefix(2)).capitalizedFirst
    }

    /// 구분자로도 가르고 글자와 숫자가 붙은 자리에서도 가른다.
    /// `team1` 은 구분자가 없지만 `team` 과 `1` 이다.
    private static func split(_ name: String) -> [Substring] {
        let byMark = name.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        var out: [Substring] = []
        for word in byMark {
            guard let edge = word.lastIndex(where: { !$0.isNumber }),
                  word.index(after: edge) < word.endIndex else { out.append(word); continue }
            out.append(word[...edge])
            out.append(word[word.index(after: edge)...])
        }
        return out
    }

    /// 글자만 쓰는 예비 표기. 그림을 못 그릴 때와 테스트가 쓴다.
    public static func label(for orgs: [OrgUsage]) -> String {
        guard !orgs.isEmpty else { return placeholder }
        if orgs.count == 1 { return percent(orgs[0]) }
        let map = codes(for: orgs.map(\.name))
        return orgs.map { "\(map[$0.name] ?? unknown) \(percent($0))" }.joined(separator: "  ")
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
