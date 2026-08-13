import Combine
import Foundation

/// 자동 재개를 실제로 돌리는 자리.
///
/// **배선만 한다.** 언제 돌릴지는 `AutoResumeWatch` 가 정하고, 어떻게 돌릴지는
/// `ResumeRunner` 가 안다. 여기는 그 둘을 잇고 지금 어느 단계인지 한 줄로
/// 내놓는다.
///
/// 메뉴바 그림을 굽는 자리에서 떼어 놓았다. 타이머로 바깥 프로세스를 띄우는
/// 권한은 사용량을 읽고 막대를 그리는 일과 성질이 다르고, 붙여 두면 그 권한이
/// AppKit 에 묶여 시험할 수 없다. docs/design/16-auto-resume.md 9절
@MainActor
public final class AutoResumeDriver: ObservableObject {
    /// 창이 보여 주는 한 줄.
    @Published public private(set) var status = AutoResumeStatus.off

    /// `claude` 실행 파일. 켤 때 한 번 찾는다.
    private let executable: URL?
    /// 결과를 사용자에게 알리는 문.
    ///
    /// `Notifier` 를 여기서 직접 부르지 않는다. 알림은 AppKit 쪽 일이라 그것을
    /// 안으로 들이면 이 타입을 알림 없이 돌려볼 수 없다.
    private let post: @MainActor (UsageAlert) async -> Void
    private var watch = AutoResumeWatch()
    /// 지금 정해 둔 것. nil 이면 꺼진 것이다.
    private var plan: AutoResumePlan?
    /// 켜 두고 세션을 아직 안 골랐다. 저장할 것이 없어 설정에는 안 남는다.
    private var pending = false
    /// 한 판이 도는 중.
    private var resuming = false

    public init(executable: URL? = ClaudeCLI.find(),
                post: @escaping @MainActor (UsageAlert) async -> Void) {
        self.executable = executable
        self.post = post
        status = idle()
    }

    /// 켤 수 있나. CLI 가 없으면 켜 봐야 돌릴 수단이 없다.
    public var canRun: Bool { executable != nil }

    /// 어느 계정을 지켜보나. 부르는 쪽이 그 계정의 사용량을 찾아 넘긴다.
    public var watchedUUID: String? { plan?.orgUUID }

    /// 지금이 판정할 때인가. **부르는 쪽이 사용량을 새로 읽을 근거다.**
    public func isDue(now: Date) -> Bool { watch.isDue(now) }

    /// 설정이 바뀌었다.
    ///
    /// `pending` 은 켜 두고 세션을 아직 안 고른 상태다. 저장할 것이 없어 `plan`
    /// 은 nil 인데 화면의 체크는 켜져 있다.
    public func planChanged(_ plan: AutoResumePlan?, pending: Bool) {
        let same = plan == self.plan
        self.plan = plan
        self.pending = pending
        guard same else {
            // 다른 세션에 걸려 있던 예약을 새 세션이 물려받으면 사용자가 정한 적
            // 없는 조합으로 돈다
            watch.forget()
            status = idle()
            return
        }
        // 저장값이 그대로여도 화면은 바뀌었을 수 있다. 세션 없이 켜기만 누른
        // 순간이 그렇다. 걸려 있는 예약과 지난 결과는 지우지 않는다
        if watch.scheduledAt == nil, !status.isResult { status = idle() }
    }

    /// 이번 읽기를 판정에 넘기고 결론을 따른다.
    ///
    /// **읽기를 마친 자리에서만 부른다.** 판정은 방금 읽은 값이라야 뜻이 있다.
    /// `org` 는 `watchedUUID` 계정의 사용량이다.
    public func step(org: OrgUsage?, readAt: Date?, now: Date) {
        guard let plan, executable != nil else {
            status = idle()
            return
        }
        // 한 판이 도는 중이면 그 결과가 상태를 정한다. 판정을 겹쳐 돌리지 않는다
        guard !resuming else { return }

        switch watch.step(org, now: now, readAt: readAt) {
        case .none:
            if let at = watch.scheduledAt {
                status = .scheduled(at)
            } else if !status.isResult {
                // 지난 결과는 다음 예약이 생길 때까지 남긴다
                status = .watching
            }
        case .run:
            status = .running
            run(plan)
        case .hold(let why):
            status = .held(why)
            let event = AutoResumeAlerts.held(why)
            Task { [post] in await post(event) }
        }
    }

    /// 예약도 결과도 없을 때의 상태.
    private func idle() -> AutoResumeStatus {
        guard executable != nil else { return .unavailable(ClaudeCLI.candidates()) }
        if plan != nil { return .watching }
        return pending ? .needsSession : .off
    }

    /// 세션을 이어 돌리고 결과를 알린다.
    ///
    /// 한 턴이 몇 분씩 가므로 기다리는 동안 화면은 `실행 중` 으로 둔다.
    private func run(_ plan: AutoResumePlan) {
        guard let executable, !resuming else { return }
        resuming = true
        let runner = ResumeRunner(executable: executable)
        Task { [weak self] in
            let status: AutoResumeStatus
            let event: UsageAlert
            do {
                let outcome = try await runner.run(plan)
                if outcome.ok {
                    status = .ran(Date())
                    event = AutoResumeAlerts.ran(plan.title)
                } else {
                    // 짐작을 덧붙이지 않는다. 종료 코드와 stderr 첫 줄이 전부다
                    let detail = "claude 가 exit \(outcome.exitCode) 로 끝났습니다."
                        + (outcome.detail.map { " \($0)" } ?? "")
                    status = .failed(detail)
                    event = AutoResumeAlerts.failed(detail)
                }
            } catch {
                let detail = "claude 를 실행하지 못했습니다. \(error.localizedDescription)"
                status = .failed(detail)
                event = AutoResumeAlerts.failed(detail)
            }
            guard let self else { return }
            self.resuming = false
            self.status = status
            await self.post(event)
        }
    }
}
