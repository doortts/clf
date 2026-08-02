import SwiftUI
import ClflDesktop

/// 겹치는 작업 폴더를 팝오버에 보여준다.
///
/// 세션은 계정을 건너갈 수 있지만 작업 트리는 안 갈라진다. 한 폴더에 세션이
/// 둘 이상 붙어 있으면 서로 남의 파일을 고칠 수 있고, 지금은 그것을 아무도
/// 모른다. docs/design/concurrent-sessions-mockup.html 2B
@MainActor
final class OverlapModel: ObservableObject {
    @Published private(set) var folders: [FolderOverlap.Folder] = []
    /// 폴더 경로 -> 겹친 세션 제목들. 개수만 보여주면 무엇인지 모른다.
    @Published private(set) var titles: [String: [String]] = [:]

    private let primary: URL

    init(primary: URL = DesktopReader.defaultSupportDirectory) {
        self.primary = primary
    }

    /// 팝오버를 열 때만 훑는다.
    ///
    /// 타이머를 걸지 않는다. 닫혀 있을 때 도는 것은 낭비이고, 열 때 한 번이면
    /// 사용자가 보는 순간의 상태로 충분하다.
    ///
    /// 기본 데이터 디렉토리만 본다. 별도 창의 레코드는 10절의 되돌리기가
    /// 5초마다 이쪽으로 복사해 두므로 여기서 같이 잡힌다.
    func refresh() {
        let stores = FolderOverlap.stores(inside: primary)
        folders = FolderOverlap.scan(stores: stores)
        // 제목은 겹친 폴더 것만 읽는다. 열 때 한 번, 많아야 서너 개다
        titles = Dictionary(uniqueKeysWithValues: folders.map {
            ($0.path, FolderOverlap.titles(ids: $0.sessionIDs))
        })
    }
}

/// 겹칠 때만 나타나는 묶음. 겹치는 일이 없으면 아무것도 그리지 않는다.
struct OverlapSection: View {
    @ObservedObject var model: OverlapModel

    var body: some View {
        if !model.folders.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("겹치는 작업 폴더")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(model.folders) { folder in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name).font(.system(size: 11, weight: .semibold))
                        // "세션 2" 같은 개수는 어느 창인지 말해주지 않는다.
                        // 제목을 보여줘야 사용자가 자기 창을 알아본다
                        ForEach(Array((model.titles[folder.path] ?? []).enumerated()),
                                id: \.offset) { _, title in
                            Text("- \(title)")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                                .padding(.leading, 10)
                        }
                    }
                }
                // 경고만 있고 길이 없으면 사용자가 막힌다. 할 일을 같이 적는다
                Text(FolderOverlap.problem)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                Text(FolderOverlap.advice)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 위 계정 카드에 붙여 두면 카드의 꼬리처럼 읽힌다. 딴 얘기임을
            // 간격으로 말한다
            .padding(.top, 10)
            .padding(.bottom, 2)
        }
    }
}
