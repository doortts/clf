import AppKit
import SwiftUI
import ClfDesktop

/// esc 로 팝오버를 닫는다.
///
/// `MenuBarExtra(.window)` 는 esc 를 안 받는다. 창의 첫 응답자가 우리 뷰가
/// 아니라서 `onExitCommand` 도 안 뜬다. 그래서 팝오버가 떠 있는 동안만 키를
/// 엿본다. 닫는 방법은 아래 이전 단추가 쓰는 것과 같다.
struct EscapeToClose: ViewModifier {
    /// esc. `NSEvent.SpecialKey` 에 없는 값이라 코드로 쓴다
    private static let escape: UInt16 = 53

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == Self.escape else { return event }
                    NSApp.keyWindow?.close()
                    // 삼킨다. 흘려보내면 뒤에 있던 창까지 같이 닫힌다
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

extension View {
    func escapeToClose() -> some View { modifier(EscapeToClose()) }
}

/// 우리가 띄운 인스턴스를 앞으로 꺼낸다.
///
/// 배경 앱에서 실행하면 창이 뒤에 뜬다. 사용자는 안 뜬 줄 알고 또 누른다.
enum AppFocus {
    static func bringToFront(pid: Int32) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateAllWindows])
    }

    /// 사용자가 원래 쓰던 창을 앞으로 꺼낸다.
    ///
    /// `ps` 로 찾을 수 없다. 별도 인스턴스만 `CLAUDE_USER_DATA_DIR` 를 달고 있고
    /// 기본 인스턴스는 표시가 없어서, 실행 파일이 같은 프로세스 중에 **우리가
    /// 띄운 pid 를 뺀** 나머지가 그것이다. 그 pid 목록은 모델이 이미 들고 있다.
    /// 못 찾으면 false 다. 데스크톱 앱이 아예 안 떠 있는 경우다.
    @discardableResult
    static func bringPrimaryToFront(excluding altPIDs: Set<Int32>) -> Bool {
        let primary = NSWorkspace.shared.runningApplications.first {
            $0.executableURL?.path == AltInstance.executable
                && !altPIDs.contains($0.processIdentifier)
        }
        guard let primary else { return false }
        return primary.activate(options: [.activateAllWindows])
    }
}
