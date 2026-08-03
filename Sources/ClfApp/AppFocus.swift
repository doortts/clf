import AppKit

/// 우리가 띄운 인스턴스를 앞으로 꺼낸다.
///
/// 배경 앱에서 실행하면 창이 뒤에 뜬다. 사용자는 안 뜬 줄 알고 또 누른다.
enum AppFocus {
    static func bringToFront(pid: Int32) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateAllWindows])
    }
}
