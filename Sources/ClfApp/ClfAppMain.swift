import SwiftUI
import ClfDesktop

/// Claude 데스크톱 앱의 계정별 잔여를 메뉴바에 둔다.
///
/// **읽기만 한다.** 앱의 파일을 고치지 않고 추론 요청도 보내지 않는다.
/// docs/design/11-menubar-app.md
@main
struct ClfMenuBarApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            // 라벨을 뷰로 주면 MenuBarExtra 가 템플릿으로 그려 색이 날아간다.
            // 구운 이미지로 넘겨야 등급 색이 남는다
            if let image = model.barImage {
                Image(nsImage: image).onAppear { begin() }
            } else {
                Text(BarText.label(for: model.barOrgs, direction: model.prefs.gaugeDirection))
                    .onAppear { begin() }
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// 넘기기 창은 팝오버를 눌러야 뜨지만, 모델은 미리 걸어 둔다.
    private func begin() {
        model.start()
        HandoffWindow.install(HandoffModel(usage: model))
    }
}
