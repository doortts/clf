import AppKit
import SwiftUI

/// 세션 넘기기 창을 띄운다.
///
/// SwiftUI `Window` 대신 `NSWindow` 를 직접 쓴다. 메뉴바 전용 앱이라 창을
/// 열어도 앱이 앞으로 안 나온다. 직접 활성화해야 사용자 눈에 보인다.
@MainActor
enum HandoffWindow {
    private static var controller: NSWindowController?
    private static var model: HandoffModel?

    /// 라벨의 onAppear 는 두 번 온다. 모델을 갈아 끼우면 창이 들고 있던
    /// 상태가 날아가므로 처음 것만 쓴다.
    static func install(_ model: HandoffModel) {
        guard self.model == nil else { return }
        self.model = model
    }

    static func open() {
        guard let model else { return }
        if controller == nil {
            let window = NSWindow(contentViewController:
                                    NSHostingController(rootView: HandoffView(model: model)))
            window.title = "세션 넘기기"
            window.styleMask = [.titled, .closable, .miniaturizable]
            // 닫아도 놓아주지 않는다. 다시 열 때 같은 창을 쓴다
            window.isReleasedWhenClosed = false
            window.center()
            controller = NSWindowController(window: window)
        }
        // 다시 열 때는 지난 결과를 지우고 계정부터 다시 본다
        model.open()
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }
}
