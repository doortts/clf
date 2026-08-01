import Foundation
import ServiceManagement
import ClflDesktop

/// `SMAppService` 를 부르는 유일한 자리.
///
/// 판단은 `LoginItemState` 가 한다. 여기는 시스템에 묻고 시키기만 한다.
enum LoginItem {
    static var bundlePath: String { Bundle.main.bundleURL.path }

    static var state: LoginItemState {
        LoginItemState.from(statusRawValue: SMAppService.mainApp.status.rawValue,
                            path: bundlePath)
    }

    /// 실패해도 던지지 않는다. 다음 `state` 조회가 진실을 말한다.
    static func set(_ enabled: Bool) {
        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    }

    /// 승인 화면을 열어준다. 경로를 말로 설명하는 것보다 낫다.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
