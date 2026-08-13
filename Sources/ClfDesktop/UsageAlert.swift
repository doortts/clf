import Foundation

/// 보낼 알림 하나.
///
/// 문구까지 여기서 만든다. 화면 쪽은 이걸 그대로 시스템에 넘기기만 한다.
/// docs/design/notify-mockup.html
public struct UsageAlert: Sendable, Equatable, Identifiable {
    public enum Level: String, Sendable {
        /// 빨강에 들어섰다. 아직 쓸 수 있다.
        case warning
        /// 다 썼다.
        case exhausted
        /// 리셋으로 다시 쓸 수 있게 됐다.
        case recovered
    }

    /// 같은 알림을 두 번 보내지 않기 위한 열쇠.
    ///
    /// 계정, 창, 등급만 담는다. **리셋 시각은 넣지 않는다.**
    ///
    /// 예전에는 넣었다. 창이 새로 열리면 다시 보낼 수 있어야 한다는 이유였는데,
    /// 서버가 `resets_at` 을 요청받은 순간에 계산해서 내려주기 때문에 값이
    /// 읽기마다 미세하게 흔들린다. 실측하면 사용률이 그대로인 창의 값이 초
    /// 경계를 넘나든다.
    ///
    /// ```
    /// weekly_scoped 잔여 17% 고정, 몇 초 간격 세 번 읽기
    ///   1786050000 -> 1786049999 -> 1786049999
    /// ```
    ///
    /// 열쇠에 이 값이 있으면 읽을 때마다 다른 알림이 되어 같은 소식이 계속 온다.
    /// 창이 새로 열린 것을 알아보는 일은 리셋 시각이 아니라 조건 자체가 한다.
    /// `Notifier` 가 사라진 조건의 열쇠를 지우므로, 빨강을 벗어났다가 다시
    /// 들어서면 그때 새 알림이 된다.
    public let key: String
    public let level: Level
    public let title: String
    public let body: String

    public var id: String { key }

    public init(key: String, level: Level, title: String, body: String) {
        self.key = key
        self.level = level
        self.title = title
        self.body = body
    }
}

/// 한 번 지나가는 소식. **조건이 아니라 사건이다.**
///
/// `UsageAlert` 과 나눠 둔다. 그쪽은 지금 참인 조건이라 두 번 보내지 않으려고
/// 열쇠를 달고 다니는데, 사건을 보내는 문(`Notifier.post`)은 그 장부를 아예
/// 안 쓴다. 쓰이지 않을 열쇠를 지어내 넘기면 읽는 사람은 그 열쇠로 무언가
/// 걸러진다고 읽는다.
public struct UsageEvent: Sendable, Equatable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// 사용량을 보고 보낼 알림을 정한다.
///
/// **본문은 `리셋: 2시간 14분 뒤` 한 줄이 기본이다.** 알림을 받는 순간 궁금한
/// 것이 그것이고 잔여 퍼센트는 제목과 메뉴바에 이미 있다. 덧붙이는 문장은
/// 한 줄만으로 오해가 생기는 경우에만 넣는다.
public enum UsageAlerts {
    /// 빨강 경계. 잔여가 이 값 이하면(사용률 95% 부터) 예고한다.
    public static let warnBelow = 5

    /// 이 계정에 보낼 알림.
    ///
    /// `others` 는 같은 화면의 다른 계정이다. 이 계정이 전부 소진일 때 여유
    /// 있는 계정 이름을 알려주는 데만 쓴다. 넘기라고 권하지는 않는다.
    public static func build(for org: OrgUsage, others: [OrgUsage] = [],
                             now: Date = Date(),
                             locale: Locale = BarText.uiLocale,
                             timeZone: TimeZone = .current) -> [UsageAlert] {
        // 값을 못 읽은 계정은 알릴 것이 없다. 0% 로 읽고 소진이라 말하면 거짓이다
        guard org.hasUsage, !org.isStale else { return [] }

        if let spend = org.spend, org.limits.isEmpty {
            return budgetAlerts(org, spend)
        }
        return windowAlerts(org, others: others, now: now, locale: locale, timeZone: timeZone)
    }

    // MARK: 시간 창

    private static func windowAlerts(_ org: OrgUsage, others: [OrgUsage], now: Date,
                                     locale: Locale, timeZone: TimeZone) -> [UsageAlert] {
        var out: [UsageAlert] = []
        let exhausted = LimitKind.allCases.filter { kind in
            org.limits[kind].map { $0.percentRemaining <= 0 } ?? false
        }

        if let binding = latest(of: exhausted, in: org) {
            // 여러 창이 소진이면 **가장 늦게 풀리는 창**이 실제로 막고 있는 창이다.
            // 5시간과 주간이 같이 소진이면 5시간 리셋은 알려줄 값이 없다
            let all = exhausted.count == LimitKind.allCases.count
            let resetsAt = org.limits[binding]?.resetsAt
            var body = BarText.resetLine(resetsAt, from: now, locale: locale, timeZone: timeZone)
            if let extra = note(all: all, binding: binding, exhausted: exhausted,
                                org: org, others: others) {
                // 리셋 줄은 마침표로 끝나지 않는다. 한 문장을 덧붙일 때만 찍는다
                body += (body.hasSuffix(".") ? " " : ". ") + extra
            }
            out.append(UsageAlert(
                key: key(org, binding.rawValue, .exhausted),
                level: .exhausted,
                title: all ? "\(org.name) 한도 전부 소진"
                           : "\(org.name) \(binding.alertLabel) 소진",
                body: body))
        }

        // 예고는 창마다 따로 보낸다. 소진된 창은 위에서 이미 말했다
        for kind in LimitKind.allCases {
            guard let limit = org.limits[kind],
                  limit.percentRemaining > 0,
                  limit.percentRemaining <= warnBelow else { continue }
            out.append(UsageAlert(
                key: key(org, kind.rawValue, .warning),
                level: .warning,
                title: "\(org.name) \(kind.alertLabel) \(limit.percentRemaining)% 남음",
                body: BarText.resetLine(limit.resetsAt, from: now,
                                        locale: locale, timeZone: timeZone)))
        }
        return out
    }

    /// 한 줄만으로 오해가 생기는 경우에만 덧붙인다.
    private static func note(all: Bool, binding: LimitKind, exhausted: [LimitKind],
                             org: OrgUsage, others: [OrgUsage]) -> String? {
        if all {
            // 이 계정이 다 막혔다. 다른 계정의 잔여는 사실이므로 알려준다
            guard let spare = spare(in: others), let left = spare.binding?.percentRemaining
            else { return nil }
            return "\(spare.name) 은 \(left)% 남았습니다."
        }
        if binding == .session, let weekly = org.limits[.weeklyAll], weekly.percentRemaining > 0 {
            // 5시간만 막힌 것이라 기다리면 이어서 쓸 수 있다는 뜻이다
            return "주간은 \(weekly.percentRemaining)% 남았습니다."
        }
        if binding == .weeklyScoped, exhausted == [.weeklyScoped] {
            // Fable 창은 모델 하나에만 걸린다. "다 막혔다" 로 읽히면 안 된다
            return "다른 모델은 쓸 수 있습니다."
        }
        return nil
    }

    /// 소진된 창 중 가장 늦게 풀리는 것. 리셋 시각을 모르는 창은 가장 늦은 것으로
    /// 본다. 언제 풀릴지 모르는 창이 곧 풀릴 창보다 덜 막고 있다고 할 수 없다.
    private static func latest(of kinds: [LimitKind], in org: OrgUsage) -> LimitKind? {
        kinds.max { lhs, rhs in
            let l = org.limits[lhs]?.resetsAt ?? .distantFuture
            let r = org.limits[rhs]?.resetsAt ?? .distantFuture
            return l < r
        }
    }

    /// 넘어갈 곳이 될 만한 계정. 빨강 경계 위로 남은 계정 중 가장 여유로운 쪽.
    private static func spare(in others: [OrgUsage]) -> OrgUsage? {
        others
            .filter { !$0.isStale && ($0.binding?.percentRemaining ?? 0) > warnBelow }
            .max { ($0.binding?.percentRemaining ?? 0) < ($1.binding?.percentRemaining ?? 0) }
    }

    // MARK: 월 예산

    private static func budgetAlerts(_ org: OrgUsage, _ spend: SpendUsage) -> [UsageAlert] {
        // 예산형은 리셋 시각이 응답에 없다. 없는 시간을 지어내지 않는다
        let unknown = "리셋 시각은 서버가 주지 않습니다."
        if spend.percentRemaining <= 0 {
            return [UsageAlert(key: key(org, "spend", .exhausted),
                               level: .exhausted,
                               title: "\(org.name) 월 예산 소진",
                               body: "\(spend.limitText) 를 다 썼습니다. " + unknown)]
        }
        guard spend.percentRemaining <= warnBelow else { return [] }
        return [UsageAlert(key: key(org, "spend", .warning),
                           level: .warning,
                           title: "\(org.name) 월 예산 \(spend.percentRemaining)% 남음",
                           body: unknown)]
    }

    // MARK: 리셋으로 풀렸을 때

    /// 빨강에 들어섰던 계정이 리셋으로 풀렸다는 알림.
    ///
    /// 판단은 `RecoveryWatch` 가 한다. 여기는 문구만 만든다. 소리는 없다.
    /// 좋은 소식이라 눈에 띄어야 할 이유가 없고, 소리를 붙이면 소진 알림과
    /// 같은 무게가 된다.
    public static func recovered(_ org: OrgUsage) -> UsageAlert? {
        guard let left = remaining(of: org) else { return nil }
        return UsageAlert(key: key(org, "org", .recovered),
                          level: .recovered,
                          title: "\(org.name) 다시 쓸 수 있습니다",
                          body: "잔여 \(left)% 로 돌아왔습니다.")
    }

    /// 이 계정을 실제로 막고 있는 잔여. 시간 창은 가장 빡빡한 창이고
    /// Enterprise 는 월 예산이다. 읽지 못한 계정은 nil 이다.
    static func remaining(of org: OrgUsage) -> Int? {
        guard org.hasUsage, !org.isStale else { return nil }
        if let spend = org.spend, org.limits.isEmpty { return spend.percentRemaining }
        return org.binding?.percentRemaining
    }

    private static func key(_ org: OrgUsage, _ scope: String,
                            _ level: UsageAlert.Level) -> String {
        [org.uuid, scope, level.rawValue].joined(separator: "|")
    }
}
