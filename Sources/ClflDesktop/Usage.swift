import Foundation

/// Claude 데스크톱 앱이 보여주는 세 줄.
///
/// ```
/// 5-hour limit          session
/// Weekly - all models   weekly_all
/// Weekly - Fable        weekly_scoped
/// ```
/// docs/design/10-desktop-usage.md 1절
public enum LimitKind: String, Sendable, CaseIterable {
    case session
    case weeklyAll = "weekly_all"
    case weeklyScoped = "weekly_scoped"

    public var label: String {
        switch self {
        case .session:      return "5시간"
        case .weeklyAll:    return "주간 전체"
        case .weeklyScoped: return "주간 Fable"
        }
    }
}

/// 한 창의 상태.
///
/// 서버는 **사용률**을 준다. 화면에는 잔여를 그리므로 그쪽은 파생시킨다.
public struct UsageLimit: Sendable, Equatable {
    public let percentUsed: Int
    /// 사용률 0 인 창은 아직 안 열려 리셋 시각이 없다. 없는 것은 nil 로 둔다.
    /// 0 이나 현재 시각으로 채우면 UI 가 거짓말한다.
    public let resetsAt: Date?
    /// 서버가 직접 주는 경고 등급. 우리 임계값과 대조할 수 있다.
    public let severity: String

    public init(percentUsed: Int, resetsAt: Date?, severity: String) {
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.severity = severity
    }

    public var percentRemaining: Int { 100 - percentUsed }

    public var band: UsageBand {
        switch percentRemaining {
        case ..<5:   return .empty
        case ..<15:  return .low
        case ..<50:  return .normal
        default:     return .ample
        }
    }
}

/// 메뉴바 색을 정하는 구간. 잔여 기준이다.
/// 잔여 구간. docs/design/ui-spec.html "색은 창마다 따로 붙는다"
///
/// 경계값은 임의가 아니다. 노랑이 시작되는 15% 는 선제 전환 임계값과 같아서
/// 노랑은 곧 "새 대화 후보에서 이미 밀려났다" 는 뜻이다.
public enum UsageBand: Sendable, Equatable, CaseIterable {
    /// 5% 미만. 사실상 소진
    case empty
    /// 5% 이상 15% 미만. 임계값 아래
    case low
    /// 15% 이상 50% 미만. 눈길을 끌지 않는다
    case normal
    /// 50% 이상. 넘어올 곳으로도 좋다
    case ample

    public var label: String {
        switch self {
        case .empty:  return "소진"
        case .low:    return "주의"
        case .normal: return "정상"
        case .ample:  return "여유"
        }
    }

    /// 배지로 내보일 만한 상태인가. 정상은 아무 말도 하지 않는다.
    public var isNoteworthy: Bool { self != .normal }
}

/// Enterprise 구독의 월 예산.
///
/// 시간 창 대신 이것이 온다. `limits` 는 빈 배열이고 `five_hour` 와
/// `seven_day` 는 전부 `null` 이다. docs/design/12-enterprise-spend.md
public struct SpendUsage: Sendable, Equatable {
    /// 최소 단위 정수. 달러면 센트다.
    public let usedMinor: Int
    public let limitMinor: Int
    public let currency: String
    /// 소수 자리 수. 달러는 2, 원은 0.
    public let exponent: Int
    /// 서버가 주는 것은 사용률이다. 잔여는 파생시킨다.
    public let percentUsed: Int
    public let severity: String

    public init(usedMinor: Int, limitMinor: Int, currency: String, exponent: Int,
                percentUsed: Int, severity: String) {
        self.usedMinor = usedMinor
        self.limitMinor = limitMinor
        self.currency = currency
        self.exponent = exponent
        self.percentUsed = percentUsed
        self.severity = severity
    }

    public var percentRemaining: Int { 100 - percentUsed }

    /// 등급 경계는 시간 창과 같다. 돈이라고 다르게 볼 이유가 없다.
    public var band: UsageBand {
        switch percentRemaining {
        case ..<5:   return .empty
        case ..<15:  return .low
        case ..<50:  return .normal
        default:     return .ample
        }
    }

    public var usedText: String { Money.text(usedMinor, self) }
    public var limitText: String { Money.text(limitMinor, self) }
}

/// 통화 기호를 우리가 정하지 않는다. 응답이 준 코드로 시스템에 맡긴다.
/// 소스에 기호를 박으면 통화가 늘 때마다 손대야 하고, 저장소 문자 규칙에도
/// 걸린다.
enum Money {
    static func text(_ minor: Int, _ spend: SpendUsage) -> String {
        let divisor = pow(10.0, Double(spend.exponent))
        let value = Double(minor) / divisor
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = spend.currency
        // 돈 표기는 en_US 로 통일한다. ko_KR 로 USD 를 그리면 US$ 가 붙는다
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = spend.exponent
        f.maximumFractionDigits = spend.exponent
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// 한 계정의 사용량 전부. 플랜에 따라 한쪽만 채워진다.
public struct UsageReport: Sendable, Equatable {
    public let limits: [LimitKind: UsageLimit]
    /// Enterprise 만 있다.
    public let spend: SpendUsage?

    public init(limits: [LimitKind: UsageLimit], spend: SpendUsage? = nil) {
        self.limits = limits
        self.spend = spend
    }

    public var isEmpty: Bool { limits.isEmpty && spend == nil }
}

public struct UsageParseError: Error, CustomStringConvertible {
    public let description: String
}

/// `limits` 배열만 읽는다.
///
/// 응답에는 `five_hour`, `seven_day` 같은 평평한 필드도 있지만 그쪽은 모델별
/// 주간을 담지 못한다. `limits` 가 세 줄을 그대로 담으므로 그것만 쓴다.
///
/// 모르는 `kind` 는 조용히 건너뛴다. 서버가 종류를 늘려도 우리가 죽으면 안 된다.
public func parseUsage(_ data: Data) throws -> [LimitKind: UsageLimit] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw UsageParseError(description: "Usage 응답이 JSON 객체가 아니다")
    }
    guard let rows = root["limits"] as? [[String: Any]] else { return [:] }

    var out: [LimitKind: UsageLimit] = [:]
    for row in rows {
        guard let raw = row["kind"] as? String, let kind = LimitKind(rawValue: raw),
              let percent = row["percent"] as? Int else { continue }
        out[kind] = UsageLimit(
            percentUsed: percent,
            resetsAt: parseTimestamp(row["resets_at"] as? String),
            severity: row["severity"] as? String ?? "")
    }
    return out
}

/// `2026-08-01T16:00:00.371815+00:00`
///
/// 마이크로초가 붙어 온다. `.withInternetDateTime` 만으로는 못 읽으므로
/// 분수 초를 켠 파서를 먼저 쓰고 없는 경우를 위해 한 번 더 시도한다.
func parseTimestamp(_ text: String?) -> Date? {
    guard let text else { return nil }
    return ISOParsers.shared.date(from: text)
}

/// ISO8601DateFormatter 는 Sendable 이 아니고 만드는 비용이 싸지 않다.
/// 메뉴바가 주기적으로 갱신하며 여러 번 부르므로 하나를 락으로 공유한다.
private final class ISOParsers: @unchecked Sendable {
    static let shared = ISOParsers()

    private let lock = NSLock()
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    private init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    func date(from text: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}

/// 시간 창과 월 예산을 함께 읽는다. 플랜에 따라 한쪽만 채워진다.
public func parseReport(_ data: Data) -> UsageReport {
    let limits = (try? parseUsage(data)) ?? [:]
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let spend = root["spend"] as? [String: Any],
          let used = spend["used"] as? [String: Any],
          let limit = spend["limit"] as? [String: Any],
          let usedMinor = used["amount_minor"] as? Int,
          let limitMinor = limit["amount_minor"] as? Int,
          // 한도가 0 이면 예산이 없는 것이다. 0 으로 나누지 않는다
          limitMinor > 0
    else { return UsageReport(limits: limits) }

    return UsageReport(limits: limits, spend: SpendUsage(
        usedMinor: usedMinor,
        limitMinor: limitMinor,
        currency: limit["currency"] as? String ?? used["currency"] as? String ?? "USD",
        exponent: limit["exponent"] as? Int ?? 2,
        percentUsed: spend["percent"] as? Int ?? 0,
        severity: spend["severity"] as? String ?? "normal"))
}
