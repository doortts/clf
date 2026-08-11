import XCTest
@testable import ClfDesktop

/// 청소부 판정. 파일은 안 건드린다.
///
/// 순서와 방향이 전부다. 헷갈리면 안 지운다. 틀려서 안 지우면 겹침 표시가
/// 남을 뿐이고, 틀려서 지우면 사용자 상태를 잃는다.
/// docs/design/15-move-janitor.html 7절
final class MoveJanitorJudgeTests: XCTestCase {
    private let mark = Date(timeIntervalSince1970: 1_700_000_000)

    private func judge(shared: Bool = false,
                       otherSideHasRecord: Bool = true,
                       windowUp: Bool = false,
                       resurrected: MoveJanitor.Resurrected? = nil,
                       cleaned: Int = 0) -> MoveJanitor.Verdict {
        MoveJanitor.judge(shared: shared, otherSideHasRecord: otherSideHasRecord,
                          windowUp: windowUp, resurrected: resurrected,
                          watermark: mark, cleaned: cleaned)
    }

    /// 옛 시각 그대로 되살아난 것이 시체다. 지운다.
    func test_staleResurrectionIsCleaned() {
        XCTAssertEqual(judge(resurrected: .init(activityAt: mark.addingTimeInterval(-60))),
                       .clean)
    }

    /// **같은 시각도 시체다.** 실측한 되살림 셋 다 옛 act 그대로였다.
    func test_equalActivityIsCleaned() {
        XCTAssertEqual(judge(resurrected: .init(activityAt: mark)), .clean)
    }

    /// 더 최신이면 사용자가 진짜 이어간 것이다. 물러나고 항목을 뺀다.
    /// 백그라운드 작업 알림도 활동을 올리는데, 그 작업은 공유 트랜스크립트에
    /// 실제로 쓰는 중이라 물러나는 것이 맞다.
    func test_newerActivityBacksOff() {
        XCTAssertEqual(judge(resurrected: .init(activityAt: mark.addingTimeInterval(1))),
                       .dropEntry)
    }

    /// 시각을 모르는 레코드는 판정할 수 없다. 지우지 않고 물러난다.
    /// 헷갈리면 안 지운다.
    func test_unknownActivityBacksOff() {
        XCTAssertEqual(judge(resurrected: .init(activityAt: nil)), .dropEntry)
    }

    /// 되살아난 것이 없으면 정상이다. 항목은 남긴다. 되살림은 22시간
    /// 뒤에도 왔다.
    func test_noResurrectionLeavesTheEntry() {
        XCTAssertEqual(judge(resurrected: nil), .leaveAlone)
    }

    /// 공유해 둔 대화는 청소부의 일이 아니다. 공유 사본을 시체로 오판해
    /// 지우면 데이터 손실이다. 항목만 뺀다.
    func test_sharedConversationIsNotOurs() {
        XCTAssertEqual(judge(shared: true, resurrected: .init(activityAt: mark)), .dropEntry)
    }

    /// 어느 계정에도 레코드가 없으면 옮김 자체가 무효다. 항목만 뺀다.
    func test_vanishedMoveDropsTheEntry() {
        XCTAssertEqual(judge(otherSideHasRecord: false,
                             resurrected: .init(activityAt: mark)), .dropEntry)
    }

    /// **창이 떠 있으면 아무것도 안 한다.** 디스크를 지워도 화면의 줄은 안
    /// 사라지고 앱의 쓰기와 얽혀 결과를 예측할 수 없다.
    func test_openWindowSkipsThisRound() {
        XCTAssertEqual(judge(windowUp: true, resurrected: .init(activityAt: mark)),
                       .skipWindowUp)
    }

    /// 안전핀. 3번 넘게 되살아나면 수동 복원을 먹고 있다는 뜻일 수 있다.
    /// 포기하고 항목을 뺀다.
    func test_giveUpAfterThreeCleanings() {
        XCTAssertEqual(judge(resurrected: .init(activityAt: mark), cleaned: 3), .dropEntry)
        XCTAssertEqual(judge(resurrected: .init(activityAt: mark), cleaned: 2), .clean)
    }

    /// 문 순서. 공유가 무효보다, 무효가 창보다 앞이다. 앞의 둘은 장부
    /// 정리라 창과 무관하게 안전하다.
    func test_gateOrder() {
        XCTAssertEqual(judge(shared: true, otherSideHasRecord: false, windowUp: true),
                       .dropEntry)
        XCTAssertEqual(judge(otherSideHasRecord: false, windowUp: true), .dropEntry)
    }
}
