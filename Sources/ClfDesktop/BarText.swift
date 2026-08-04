import Foundation

/// 메뉴바 막대에 들어갈 글자.
///
/// 막대는 다른 앱과 자리를 나눠 쓴다. 계정 이름을 그대로 넣으면 화면 절반을
/// 먹는다. 팝오버에는 전체 이름이 나오므로 여기서는 구별만 되면 된다.
public enum BarText {
    public static let placeholder = "clf"
    /// 사용량을 못 읽은 계정. 0% 로 그리면 한도가 찬 것처럼 보인다.
    public static let unknown = "?"

    /// 계정 이름을 두세 글자로 줄인다.
    ///
    /// docs/design/ui-spec.html "계정 이름 대신 두 글자 코드를 쓴다".
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
        // 따르면 계정이 늘고 줄 때마다 코드가 흔들려 눈이 못 따라간다
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
    public static func label(for orgs: [OrgUsage],
                             direction: GaugeDirection = .remaining) -> String {
        guard !orgs.isEmpty else { return placeholder }
        if orgs.count == 1 { return percent(orgs[0], direction) }
        let map = codes(for: orgs.map(\.name))
        return orgs.map { "\(map[$0.name] ?? unknown) \(percent($0, direction))" }
            .joined(separator: "  ")
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

    /// 막대 라벨 자리에 들어가는 남은 시간. 숫자 하나와 단위 한 글자다.
    ///
    /// **내림한다.** `3h` 는 "아직 3시간은 남았다" 는 뜻이고 올림하면 없는
    /// 시간을 약속한다. 단위도 하나만 쓴다. `3h44m` 은 폭이 두 배인데 막대에서
    /// 그 정확도는 쓸모가 없다.
    ///
    /// ```
    /// 6일 23시간 -> 6d      23시간 40분 -> 23h
    /// 4시간 6분  -> 4h      9분 50초    -> 9m
    /// 30초       -> 0m      리셋 시각 없음 -> -
    /// ```
    ///
    /// 사용률 0 인 창은 타이머가 안 걸려서 리셋 시각이 없다. 막대는 그 자리를
    /// 아예 비우므로 이 함수를 부르지 않는다. `-` 는 다른 부르는 쪽을 위한
    /// 마지막 방어다. docs/design/bar-reset-remaining-mockup.html
    public static func shortUntil(_ date: Date?, from now: Date = Date()) -> String {
        guard let left = date.map({ $0.timeIntervalSince(now) }) else { return "-" }
        // 시계가 어긋나 지난 시각이 와도 음수를 그리지 않는다
        guard left > 0 else { return "0m" }

        let days = Int(left / 86400)
        if days > 0 { return "\(days)d" }
        let hours = Int(left / 3600)
        if hours > 0 { return "\(hours)h" }
        return "\(Int(left / 60))m"
    }

    /// 마지막으로 쓴 때를 사람이 읽는 말로. `until` 의 반대 방향이다.
    ///
    /// 단위 하나면 된다. 목록에서 순서를 가늠하는 값이라 "2시간 13분 전" 처럼
    /// 정확할 이유가 없다.
    public static func since(_ date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "" }
        // 시계가 어긋나면 미래로 찍힌다. 음수를 그대로 보여주면 고장으로 보인다
        let past = max(0, Int(now.timeIntervalSince(date)))
        switch past {
        case ..<60:      return "방금"
        case ..<3600:    return "\(past / 60)분 전"
        case ..<86_400:  return "\(past / 3600)시간 전"
        case ..<172_800: return "어제"
        default:         return "\(past / 86_400)일 전"
        }
    }

    /// 남은 시간에 리셋 시각을 곁들인다.
    ///
    /// **하루를 넘는 창에만 붙인다.** `5일 1시간 뒤` 만으로는 그게 언제인지
    /// 감이 안 오지만, 하루 안쪽이면 남은 시간만으로 충분하고 괄호는 잡음이다.
    ///
    /// ```
    /// 리셋: 3시간 36분 뒤
    /// 리셋: 5일 1시간 뒤 (금요일 오전 6:00)
    /// 창 안 열림
    /// ```
    ///
    /// 창이 안 열렸으면 `리셋:` 을 안 붙인다. 리셋할 것이 아직 없다.
    /// 로케일은 한국어로 못박는다. 화면 글자가 전부 한국어인데 시각만
    /// 시스템 로케일을 따르면 `5일 1시간 뒤 (Friday 6:00 AM)` 이 된다.
    /// 실제로 그렇게 나왔다. 시간대는 시스템을 따른다. 그건 사용자가 어디
    /// 있는지의 문제지 언어가 아니다.
    public static let uiLocale = Locale(identifier: "ko_KR")

    public static func reset(_ date: Date?, window: TimeInterval? = nil,
                             direction: GaugeDirection = .used,
                             from now: Date = Date(),
                             locale: Locale = BarText.uiLocale,
                             timeZone: TimeZone = .current) -> String {
        let relative = until(date, from: now)
        // 아직 안 열린 창은 리셋 시각이 없다. 진행률도 낼 수 없다
        guard let date else { return relative }

        // 남은 시간만 보면 그 창이 얼마나 지났는지는 모른다. 5시간 창의
        // 10분과 주간 창의 10분은 뜻이 다르다.
        //
        // 방향은 게이지를 따른다. 지난 시간은 시간의 '사용률' 쪽이다. 게이지가
        // 남은 용량을 세는데 리셋만 지난 비율을 세면 두 숫자가 반대로 움직인다
        let done = window.map { w -> String in
            let elapsed = elapsedPercent(until: date, window: w, from: now)
            return "\(direction.displayPercent(used: elapsed))%, "
        } ?? ""
        guard date.timeIntervalSince(now) > 86400 else { return prefix + done + relative }
        return prefix + done + relative
            + " (" + Clocks.shared.stamp(date, locale: locale, timeZone: timeZone) + ")"
    }

    /// 창이 얼마나 지났나. 100% 에 닿으면 리셋이다.
    ///
    /// 시계가 어긋나면 창 길이보다 더 남은 것으로 나올 수 있다. 음수나
    /// 100 을 넘는 값을 보여주면 고장으로 보이므로 가둔다.
    public static func elapsedPercent(until date: Date, window: TimeInterval,
                                      from now: Date) -> Int {
        guard window > 0 else { return 100 }
        let left = date.timeIntervalSince(now)
        return min(100, max(0, Int(((window - left) / window * 100).rounded())))
    }

    static let prefix = "리셋: "

    /// 가장 좁은 창을 쓴다. 5시간이 널널해도 주간이 바닥이면 바닥이 사실이다.
    private static func percent(_ org: OrgUsage, _ direction: GaugeDirection) -> String {
        guard let binding = org.binding else { return unknown }
        return "\(direction.displayPercent(used: binding.percentUsed))%"
    }
}

private extension String {
    /// 나머지는 건드리지 않는다. `ID` 를 `Id` 로 바꾸면 안 된다.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// `DateFormatter` 는 Sendable 이 아니고 만드는 비용이 싸지 않다. 메뉴바가
/// 주기적으로 갱신하며 계정마다 세 번씩 부르므로 하나를 락으로 공유한다.
/// `Usage.swift` 의 `ISOParsers` 와 같은 이유다.
private final class Clocks: @unchecked Sendable {
    static let shared = Clocks()

    private let lock = NSLock()
    private let formatter = DateFormatter()
    private var configured: (locale: Locale, zone: TimeZone)?

    /// 형식을 직접 쓴다.
    ///
    /// 처음에는 `setLocalizedDateFormatFromTemplate` 로 줬는데 ko_KR 이
    /// 요일을 괄호로 감싼 형식을 돌려줘 `((금요일) 오전 5:59)` 가 나왔다.
    /// 우리가 이미 괄호를 치고 있어서 겹친 것이다. 로케일을 한국어로
    /// 못박은 이상 형식도 우리가 정하는 편이 맞다.
    func stamp(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        lock.lock(); defer { lock.unlock() }
        if configured?.locale != locale || configured?.zone != timeZone {
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = "EEEE a h:mm"
            configured = (locale, timeZone)
        }
        return formatter.string(from: date)
    }
}
