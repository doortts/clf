import Foundation

/// 옮긴 자리의 청소부.
///
/// 옮기기가 지운 레코드를 앱이 종료 flush 로 되살린다. 장부(`MovedSessions`)의
/// 대화만 보고, 되살아난 레코드를 워터마크와 비교해 시체만 다시 지운다.
///
/// **창이 떠 있는 동안은 아무것도 안 지운다.** 화면의 줄은 앱 메모리라 디스크를
/// 지워도 효과가 없고, 앱의 쓰기와 얽히면 결과를 예측할 수 없다. 창이 없으면
/// 되살릴 프로세스가 없어 한 번 지우면 끝난다.
/// docs/design/15-move-janitor.html
public enum MoveJanitor {
    /// 옛 자리에 되살아난 레코드.
    public struct Resurrected: Sendable, Equatable {
        public let activityAt: Date?
        public init(activityAt: Date?) { self.activityAt = activityAt }
    }

    public enum Verdict: Sendable, Equatable {
        /// 정상. 항목은 남긴다. 되살림은 며칠 뒤에도 온다
        case leaveAlone
        /// 창이 떠 있다. 이번 바퀴는 넘어간다
        case skipWindowUp
        /// 청소부의 일이 아니게 됐다. 장부에서만 뺀다
        case dropEntry
        /// 되살아난 시체다. 지우고 무덤을 남기고 안전핀을 센다
        case clean
    }

    /// 판정. 파일은 안 건드린다. 7절 흐름도 그대로다.
    ///
    /// 헷갈리면 안 지운다. 시각을 모르는 레코드도 물러난다. 틀려서 안 지우면
    /// 겹침 표시가 남을 뿐이고, 틀려서 지우면 사용자 상태를 잃는다.
    public static func judge(shared: Bool,
                             otherSideHasRecord: Bool,
                             windowUp: Bool,
                             resurrected: Resurrected?,
                             watermark: Date,
                             cleaned: Int) -> Verdict {
        // 앞의 두 문은 삭제가 아니라 장부 정리라 창과 무관하게 안전하다
        if shared { return .dropEntry }
        if !otherSideHasRecord { return .dropEntry }
        if windowUp { return .skipWindowUp }
        guard let resurrected else { return .leaveAlone }
        guard let at = resurrected.activityAt, at <= watermark else { return .dropEntry }
        guard cleaned < MovedSessions.cleanLimit else { return .dropEntry }
        return .clean
    }
}
