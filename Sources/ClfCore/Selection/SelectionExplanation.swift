import Foundation

/// 후보 하나에 대한 판정과 그 이유.
///
/// 선택기가 결과만 내면 "왜 team2 로 안 넘어갔나" 를 로그를 뒤져 재구성해야 한다.
/// 이유를 값으로 만들어 두면 오프라인 재생과 실행 중 관찰이 **같은 레코드**를 본다.
/// docs/design/08-verification.md 3절
public struct CandidateVerdict: Sendable, Equatable {
    public let id: AccountID
    public let disposition: Disposition
    /// 판정 시점의 구속 여유. 읽기가 없으면 nil.
    public let headroom: Double?

    public enum Disposition: Sendable, Equatable {
        /// 이번에 고른 조직.
        case chosen
        /// 후보로 남았으나 위에 더 앞선 조직이 있었다.
        case candidate(tier: Int)
        /// 이 요청에서 이미 시도했다.
        case alreadyTried
        /// 사용자가 자동 전환에서 뺐다. usableNow 면 켜는 즉시 풀린다.
        case autoSwitchOff(usableNow: Bool)
        case invalid(since: Date)
        case cooling(until: Date, scope: CooldownScope)
        /// priority 에는 있는데 accounts 에 없다. 정규화가 놓친 경우.
        case unknownAccount
    }

    public init(id: AccountID, disposition: Disposition, headroom: Double?) {
        self.id = id
        self.disposition = disposition
        self.headroom = headroom
    }

    /// 사람이 읽는 한 줄. 표의 마지막 칸에 그대로 들어간다.
    public var reason: String {
        switch disposition {
        case .chosen:                     return "선택"
        case .candidate(let tier):        return "대기 (tier \(tier))"
        case .alreadyTried:               return "이번 요청에서 이미 시도"
        case .autoSwitchOff(let usable):  return usable ? "자동 전환 꺼짐 (켜면 바로 쓸 수 있다)"
                                                        : "자동 전환 꺼짐"
        case .invalid:                    return "자격증명 무효"
        case .cooling(let until, .account):
            return "계정 쿨다운 \(Self.clock.string(from: until)) 까지"
        case .cooling(let until, .model(let m)):
            return "\(m) 쿨다운 \(Self.clock.string(from: until)) 까지"
        case .unknownAccount:             return "등록되지 않은 id"
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// 결과와 판정 목록. 목록 순서는 priority 순서 그대로다.
public struct SelectionExplanation: Sendable, Equatable {
    public let result: SelectionResult
    public let verdicts: [CandidateVerdict]

    public init(result: SelectionResult, verdicts: [CandidateVerdict]) {
        self.result = result
        self.verdicts = verdicts
    }
}
