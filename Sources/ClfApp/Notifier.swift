import AppKit
import UserNotifications
import ClfDesktop

/// 데스크톱 알림을 보낸다.
///
/// **같은 알림을 두 번 보내지 않는 것이 이 타입의 절반이다.** 읽기가 몇 분마다
/// 도는데 조건만 보고 보내면 한 시간에 열 번 넘게 온다. 한 번 보낸 열쇠를 들고
/// 있다가, 그 조건이 사라지면 열쇠도 지워 다음 번을 위해 다시 무장한다.
/// docs/design/notify-mockup.html
@MainActor
final class Notifier {
    /// 권한 상태. 켜져 있어도 시스템이 막으면 알림은 안 온다.
    enum Permission: Equatable {
        /// 아직 안 물어봤다.
        case unknown
        case granted
        case denied
    }

    private(set) var permission: Permission = .unknown
    /// 이미 보낸 알림의 열쇠.
    private var sent: Set<String> = []
    private let center = UNUserNotificationCenter.current()

    /// 지금 권한이 어떤지 물어본다. 사용자에게 창을 띄우지 않는다.
    func refreshPermission() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: permission = .granted
        case .denied:                               permission = .denied
        default:                                    permission = .unknown
        }
    }

    /// 권한을 요청한다. 설정에서 알림을 켤 때 한 번 부른다.
    ///
    /// 우리 앱은 임시 서명이라 요청 자체가 실패할 수 있다. 그때는 거절로 보고
    /// 설정 화면이 시스템 설정으로 가는 길을 안내한다.
    func request() async {
        do {
            let ok = try await center.requestAuthorization(options: [.alert, .sound])
            permission = ok ? .granted : .denied
        } catch {
            permission = .denied
        }
    }

    /// 새 알림만 보낸다. 사라진 조건의 열쇠는 지운다.
    ///
    /// `alerts` 는 **지금 참인 조건 전부**여야 한다. 일부만 넘기면 넘기지 않은
    /// 조건의 열쇠가 지워져서 다음 읽기에 같은 알림이 다시 온다.
    func deliver(_ alerts: [UsageAlert]) async {
        let live = Set(alerts.map(\.key))
        // 등급이 좋아지면 그 알림은 다시 보낼 수 있어야 한다
        sent.formIntersection(live)

        guard permission == .granted else { return }
        for alert in alerts where !sent.contains(alert.key) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            // 소진은 소리까지. 예고는 조용히 쌓인다
            if alert.level == .exhausted { content.sound = .default }
            let request = UNNotificationRequest(identifier: alert.key,
                                                content: content, trigger: nil)
            do {
                try await center.add(request)
                sent.insert(alert.key)
            } catch {
                // 한 번 실패한 것을 보냈다고 표시하면 다시는 안 온다
                continue
            }
        }
    }

    /// 알림을 껐다가 다시 켰을 때, 그동안의 조건을 새 소식으로 받는다.
    func forgetAll() { sent.removeAll() }

    /// 지금 참인 조건을 보낸 것으로 표시만 한다. 앱을 켠 직후 첫 읽기에 쓴다.
    ///
    /// 이미 빨강인 상태로 켠 것은 새 소식이 아니다. 켜자마자 알림 셋이 쏟아지면
    /// 그 뒤로 알림을 꺼 버린다.
    func markSeen(_ alerts: [UsageAlert]) {
        sent = Set(alerts.map(\.key))
    }

    /// 시스템 설정의 알림 창을 연다.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
