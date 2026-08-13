import Foundation

/// 무엇을 언제 이어 돌릴지. 사용자가 창에서 정한다.
///
/// nil 이면 꺼진 것이다. 세션을 고르는 것이 곧 켜는 것이라, 켜 두고 세션만
/// 안 고른 상태는 저장하지 않는다. 화면에서 그 상태로 머무는 동안은
/// `AutoResumeStatus.needsSession` 이 대신 말한다.
/// docs/design/16-auto-resume.md 8절
public struct AutoResumePlan: Codable, Sendable, Equatable {
    /// 한도를 지켜볼 계정. **실행 계정이 아니다.** CLI 는 자기 로그인 계정으로
    /// 돈다. 5절
    public var orgUUID: String
    public var sessionID: String
    /// 세션의 작업 디렉토리. `--resume` 은 그 자리에서 실행해야 찾는다.
    public var cwd: String
    /// 창에 적을 이름. 세션 파일이 사라져도 무엇을 골랐는지는 보여야 한다.
    public var title: String
    public var prompt: String

    public static let defaultPrompt = "이어서 진행해줘"

    public init(orgUUID: String, sessionID: String, cwd: String, title: String,
                prompt: String = defaultPrompt) {
        self.orgUUID = orgUUID
        self.sessionID = sessionID
        self.cwd = cwd
        self.title = title
        self.prompt = prompt
    }
}

/// 지금 자동 재개가 어느 단계인가. 창이 이 한 줄을 보여준다.
///
/// **문구까지 여기서 만든다.** `UsageAlerts` 가 알림 문구를 만드는 것과 같은
/// 자리다. 뷰는 글자와 색을 받아 그리기만 한다.
/// docs/design/auto-resume-mockup.html 3절
public enum AutoResumeStatus: Sendable, Equatable {
    /// 꺼져 있다. 세션을 안 골랐다.
    case off
    /// 켜 두었지만 세션을 아직 안 골랐다.
    ///
    /// 저장된 것은 없다. 화면의 체크만 켜져 있다. 이 자리를 `.off` 로 두면
    /// 체크는 켜졌는데 상자는 꺼져 있다고 말해서 둘이 서로 다른 말을 한다.
    case needsSession
    /// CLI 가 없어 켤 수 없다.
    case unavailable([String])
    /// 켜져 있고 소진을 지켜보는 중.
    case watching
    /// 소진을 봤고 이 시각에 판정한다.
    case scheduled(Date)
    /// 지금 돌리는 중.
    case running
    /// 이 시각에 돌렸다.
    case ran(Date)
    /// 규칙대로 안 돌렸다.
    case held(String)
    /// 돌리다 깨졌다.
    case failed(String)

    /// 왼쪽 색 띠. 팝오버 게이지와 같은 어휘다.
    public enum Accent: Sendable, Equatable {
        case none, good, wait, bad
    }

    /// 지난 결과인가.
    ///
    /// 결과는 다음 예약이 생길 때까지 화면에 남는다. 지켜보는 중이라고 덮으면
    /// 사용자가 창을 열었을 때 방금 무슨 일이 있었는지 알 길이 없다.
    public var isResult: Bool {
        switch self {
        case .ran, .held, .failed: return true
        default:                   return false
        }
    }

    public var accent: Accent {
        switch self {
        case .off:                    return .none
        case .watching, .ran:         return .good
        case .scheduled, .running:    return .wait
        case .unavailable, .needsSession: return .wait
        case .held, .failed:          return .bad
        }
    }

    /// 상태 상자 한 줄.
    ///
    /// 시각은 상대값으로 적는다. 주간 리셋은 며칠 뒤라 시계만 적으면
    /// 오늘로 읽힌다.
    public func text(now: Date = Date()) -> String {
        switch self {
        case .off:
            return "꺼져 있습니다. 켜면 고른 세션을 리셋 뒤에 이어 돌립니다."
        case .needsSession:
            return "이어 돌릴 세션을 고르면 켜집니다."
        case .unavailable(let searched):
            return "claude CLI 를 찾지 못했습니다. 찾아본 곳: "
                + searched.joined(separator: ", ")
        case .watching:
            return "5시간, 주간 창을 지켜보는 중입니다."
                + " 소진되면 리셋 3분 뒤에 이 세션을 이어 돌립니다."
        case .scheduled(let at):
            // 그 시각에 무조건 도는 것이 아니다. 시각만 적으면 그렇게 읽힌다.
            // 예약 시각이 지나 새 사용량을 기다리는 동안은 `곧` 이다. `until` 이
            // 그 자리에서 돌려주는 `지남` 은 예약을 취소한 것처럼 읽힌다
            let when = at.timeIntervalSince(now) > 60
                ? BarText.until(at, from: now) + "에"
                : "곧"
            return "한도가 소진됐습니다. \(when) 재개합니다. 그때 잔여를 다시 확인합니다."
        case .running:
            return "재개를 실행하는 중입니다."
        case .ran(let at):
            // `방금`, `어제` 에는 조사가 붙지 않고 `5분 전` 에는 붙는다
            let ago = BarText.since(at, from: now)
            return "\(ago.hasSuffix("전") ? ago + "에" : ago) 이어 돌렸습니다."
                + " 다시 지켜보는 중입니다."
        case .held(let why):
            return why + " 다음 리셋에 다시 확인합니다."
        case .failed(let detail):
            return "재개하지 못했습니다. " + detail
        }
    }
}

/// 판정이 내린 결론.
public enum AutoResumeAction: Sendable, Equatable {
    /// 지금은 할 일이 없다.
    case none
    /// 이어 돌린다.
    case run
    /// 안 돌린다. 이유는 사용자에게 그대로 보여준다.
    case hold(String)
}

/// 언제 이어 돌릴지 정하는 판정.
///
/// **시각과 사용량만 본다.** 프로세스를 띄우는 일도, 사용량을 읽는 일도 하지
/// 않는다. 그 둘은 부르는 쪽 몫이고, 여기는 부르는 쪽이 그것을 언제 해야
/// 하는지만 답한다. 그래서 시계를 주입해 통째로 검증할 수 있다.
/// docs/design/16-auto-resume.md 2절, 3절
public struct AutoResumeWatch: Sendable, Equatable {
    /// 지켜보는 창.
    ///
    /// `weekly_scoped` 는 뺀다. 모델 하나에만 걸리는 창이라 소진돼도 다른
    /// 모델로 이어갈 수 있고, 재개를 막을 이유가 못 된다.
    public static let watched: [LimitKind] = [.session, .weeklyAll]

    /// 리셋 뒤 이만큼 기다린다.
    ///
    /// 서버가 주는 `resets_at` 은 읽을 때마다 초 단위로 흔들린다
    /// (UsageAlert.swift 주석). 리셋 시각에 딱 맞춰 돌리면 아직 안 풀린 창을
    /// 보고 보류할 수 있다. 3분이 그 흔들림을 흡수한다.
    public static let delay: TimeInterval = 3 * 60

    /// 이 잔여 미만이면 안 돌린다.
    ///
    /// 알림이 빨강을 예고하는 경계(`UsageAlerts.warnBelow`)와 같은 숫자다.
    /// 부등호만 다르다. 알림은 이 값 **이하**를 경고하고, 여기는 이 값
    /// **이상**일 때 돈다. 마지막 남은 몫은 사람이 쓸 자리다.
    public static let minRemaining = 5

    /// 판정에 쓸 사용량이 이보다 오래되면 판정하지 않는다.
    ///
    /// 리셋 직전에 읽은 값은 0% 다. 그것으로 판정하면 방금 풀린 창을 보고
    /// 보류한다. 예약을 그대로 두고 기다리면 부르는 쪽이 다시 읽어 온다.
    static let freshWithin: TimeInterval = 90

    /// 예약된 재개 시각.
    private var due: Date?
    /// 마지막으로 판정을 끝낸 예약 시각. 같은 리셋에 두 번 돌지 않기 위해.
    private var decided: Date?

    public init() {}

    /// 예약된 시각. 창이 상태를 그릴 때 쓴다.
    public var scheduledAt: Date? { due }

    /// 지금이 판정할 때인가. **부르는 쪽이 사용량을 새로 읽을 근거다.**
    ///
    /// 판정 자체는 `step` 이 한다. 여기가 참인데 값이 낡았으면 `step` 은
    /// 예약을 유지한 채 아무 일도 하지 않으므로, 부르는 쪽은 먼저 읽고
    /// `step` 을 부르면 된다.
    public func isDue(_ now: Date) -> Bool {
        guard let due else { return false }
        return now >= due
    }

    /// 예약과 기억을 지운다. 계정이나 세션이 바뀌면 이전 예약은 뜻이 없다.
    public mutating func forget() {
        due = nil
        decided = nil
    }

    /// 이번 읽기를 반영하고 할 일을 돌려준다.
    ///
    /// `readAt` 은 `org` 를 읽어온 시각이다. nil 이면 아직 한 번도 못 읽었다.
    public mutating func step(_ org: OrgUsage?, now: Date, readAt: Date?) -> AutoResumeAction {
        guard let org else {
            // 볼 계정이 없으면 예약을 들고 있을 근거도 없다. **그냥 두면 부르는
            // 쪽이 판정할 때가 됐다고 매분 사용량을 다시 읽는다.** 계정이 다시
            // 보이고 그때도 소진이면 다시 예약된다.
            //
            // 읽기가 실패한 계정은 `mergeKeepingLastGood` 이 지난 값으로 남기므로
            // 여기로 오지 않는다. 서버가 계정을 아예 안 주는 경우다
            due = nil
            return .none
        }

        if let due {
            guard now >= due else { return .none }
            // 낡은 값으로는 판정하지 않는다. 예약은 그대로 두고 다음 읽기를 기다린다
            guard let readAt, now.timeIntervalSince(readAt) <= Self.freshWithin,
                  org.hasUsage, !org.isStale
            else { return .none }
            self.due = nil
            decided = due
            return verdict(org)
        }

        guard let at = blockedUntil(org) else { return .none }
        let candidate = at.addingTimeInterval(Self.delay)
        // 판정을 끝낸 리셋과 같은 것이면 다시 예약하지 않는다. 초 단위로
        // 흔들리는 값이라 같은 시각인지는 분 단위로 본다
        if let decided, abs(candidate.timeIntervalSince(decided)) < 60 { return .none }
        due = candidate
        return .none
    }

    /// 지금 이 계정을 막고 있는 창의 리셋 시각.
    ///
    /// 소진된 창 중 **가장 늦게 풀리는 것**이다. 5시간과 주간이 같이 소진이면
    /// 5시간이 풀려도 여전히 못 쓴다. `UsageAlerts` 가 알림에서 쓰는 기준과
    /// 같다.
    ///
    /// 소진된 창의 리셋 시각을 모르면 nil 이다. **언제 풀릴지 모르는 창은
    /// 기다릴 수 없다.** 없는 시각을 지어내 예약하면 그 시점에 아직 소진인
    /// 창을 보고 보류하고, 그 리셋을 통째로 건너뛴다.
    private func blockedUntil(_ org: OrgUsage) -> Date? {
        guard org.hasUsage, !org.isStale else { return nil }
        var latest: Date?
        for kind in Self.watched {
            guard let limit = org.limits[kind], limit.percentRemaining <= 0 else { continue }
            guard let at = limit.resetsAt else { return nil }
            latest = max(latest ?? at, at)
        }
        return latest
    }

    /// 지켜보는 창이 전부 기준 이상 남았나. 하나라도 모자라면 이유를 담아 보류한다.
    ///
    /// 없는 창은 안 막는다. 플랜에 따라 주간 창이 없을 수 있고, 없는 창을
    /// 0% 로 치면 그 계정은 영영 못 돈다.
    private func verdict(_ org: OrgUsage) -> AutoResumeAction {
        for kind in Self.watched {
            guard let limit = org.limits[kind] else { continue }
            guard limit.percentRemaining >= Self.minRemaining else {
                return .hold("\(kind.label) 잔여가 \(limit.percentRemaining)% 라"
                             + " 이번 리셋에는 재개하지 않았습니다")
            }
        }
        return .run
    }
}

/// 자동 재개가 보내는 알림 문구.
///
/// **결과만 알린다.** 예약은 알리지 않는다. 소진 알림이 이미 갔고 예약은 창
/// 안 상태에 있다. 창을 닫아 두고 지내는 기능이라 결과는 알림으로 와야 한다.
///
/// 셋 다 소리가 없다. 소리는 소진에만 붙는다(`Notifier`). 자동으로 돈 일에
/// 소리를 붙이면 소진 알림과 같은 무게가 된다. 사건에는 소리를 붙일 자리도
/// 두 번 보내지 않으려는 열쇠도 없다.
/// docs/design/auto-resume-mockup.html 5절
public enum AutoResumeAlerts {
    public static func ran(_ title: String) -> UsageEvent {
        UsageEvent(title: "세션 자동 재개",
                   body: "\(title) 세션을 이어서 실행했습니다")
    }

    public static func held(_ why: String) -> UsageEvent {
        UsageEvent(title: "자동 재개 보류", body: why)
    }

    public static func failed(_ detail: String) -> UsageEvent {
        UsageEvent(title: "자동 재개 실패", body: detail)
    }
}
