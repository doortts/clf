import SwiftUI
import ClflDesktop

/// Claude 데스크톱 앱의 조직별 잔여를 메뉴바에 둔다.
///
/// **읽기만 한다.** 앱의 파일을 고치지 않고 추론 요청도 보내지 않는다.
/// docs/design/11-menubar-app.md
@main
struct ClflMenuBarApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            // 이미지 없이 글자만. 잔여 숫자가 곧 아이콘이다
            Text(BarText.label(for: model.barOrgs))
                .onAppear { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
