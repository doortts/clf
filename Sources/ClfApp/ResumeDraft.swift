import Foundation
import ClfDesktop

/// 자동 재개 탭이 만지고 있는 초안.
///
/// **저장된 것과 따로 든다.** 저장은 켜기와 세션이 둘 다 정해져야 성립하는데
/// 사용자는 켜기부터 누른다. 초안이 없으면 세션을 고르기 전에 누른 켜기가
/// 갈 곳이 없다.
///
/// 세션을 넘기는 창(`HandoffModel`)과 나눠 둔다. 한 창에 있어도 다른 일이고,
/// 한 덩어리로 두면 넘기기 상태와 재개 초안이 서로의 이유를 가린다.
/// docs/design/16-auto-resume.md 7절
@MainActor
final class ResumeDraft: ObservableObject {
    @Published private(set) var on = false
    @Published private(set) var accountUUID = ""
    /// 고른 세션. **id 가 아니라 세션 자체를 든다.** 목록에서 밀려난 세션도
    /// 저장값으로 되살려 여기 두므로, 저장할 때 목록을 다시 뒤질 필요가 없다.
    @Published private(set) var session: CliSession?
    @Published private(set) var prompt = AutoResumePlan.defaultPrompt
    /// 이어 돌릴 후보. CLI 가 아는 세션이라 작업 이전 탭의 목록과 출처가 다르다.
    @Published private(set) var sessions: [CliSession] = []

    private unowned let usage: UsageModel
    /// 계정 목록은 넘기기 창이 만드는 것을 그대로 빌린다. 같은 목록을 두 번
    /// 만들면 창이 떠 있는 계정 표시가 두 탭에서 어긋난다.
    private unowned let handoff: HandoffModel

    init(usage: UsageModel, handoff: HandoffModel) {
        self.usage = usage
        self.handoff = handoff
    }

    /// 켤 수 있나. CLI 가 없으면 고를 것도 없다.
    var canEdit: Bool { usage.canAutoResume }

    /// 상태를 들고 있는 쪽. **탭이 이것을 직접 본다.**
    ///
    /// 여기서 계산 프로퍼티로 넘겨주면 값은 맞지만 창이 안 다시 그려진다.
    /// 초안이 바뀔 때만 알림이 나가는데, 상태는 초안과 무관하게 읽기 주기와
    /// 실행 결과로 바뀌기 때문이다. 창을 열어 둔 채 재개가 끝나면 상자가
    /// `실행 중` 에서 멈춰 있었다.
    var driver: AutoResumeDriver { usage.resumeDriver }
    var accounts: [HandoffModel.Account] { handoff.accounts }
    var chosenAccount: HandoffModel.Account? { handoff.account(accountUUID) }

    /// 창을 열 때. 저장된 것을 초안으로 옮기고 목록을 훑는다.
    func open() {
        let saved = usage.autoResume
        on = saved != nil
        prompt = saved?.prompt ?? AutoResumePlan.defaultPrompt
        accountUUID = saved?.orgUUID
            ?? accounts.first(where: { $0.slot == .primary })?.uuid
            ?? accounts.first?.uuid ?? ""
        // 저장값에서 세션을 되살린다. 목록에 없을 수 있다. 목록은 최근 열 개로
        // 자르므로 골라 둔 세션이 밀려났거나 프로젝트가 지워진 경우다
        session = saved.map { CliSession(id: $0.sessionID, title: $0.title, cwd: $0.cwd,
                                         modifiedAt: .distantPast) }
        loadSessions()
    }

    /// 목록은 파일을 훑어야 안다. 창을 여는 길목을 막지 않는다.
    private func loadSessions() {
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                CliSessions.scan()
            }.value
            self?.sessions = found
        }
    }

    func setOn(_ value: Bool) {
        on = value
        commit()
    }

    func setAccount(_ uuid: String) {
        accountUUID = uuid
        commit()
    }

    /// 하나만 고른다. 다시 누르면 고른 것을 놓는다.
    ///
    /// **고르는 것이 곧 켜는 것이다.** 꺼 둔 채로 고르면 아무 일도 안 일어나서
    /// 누른 것이 먹었는지 알 수 없다. 놓을 때는 끄지 않는다. 다른 세션으로
    /// 갈아타는 중일 수 있다.
    func pick(_ picked: CliSession) {
        session = session?.id == picked.id ? nil : picked
        if session != nil { on = true }
        commit()
    }

    func setPrompt(_ text: String) {
        prompt = text
        commit()
    }

    /// 초안이 성립하면 저장하고, 아니면 끈 것으로 저장한다.
    ///
    /// 켜 두고 세션을 안 고른 상태는 저장하지 않는다. 그 상태로 저장하면 무엇을
    /// 돌릴지 없는 예약이 남는다. 창은 초안을 그대로 보여주므로 켜기는 눌린
    /// 채로 있고, 아래 상태 상자가 무엇이 빠졌는지 말한다.
    private func commit() {
        guard on, let session else {
            usage.setAutoResume(nil, pending: on)
            return
        }
        usage.setAutoResume(AutoResumePlan(orgUUID: accountUUID, sessionID: session.id,
                                           cwd: session.cwd, title: session.title,
                                           prompt: prompt))
    }
}
