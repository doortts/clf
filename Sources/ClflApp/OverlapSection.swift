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
                    HStack(spacing: 6) {
                        Text(folder.name).font(.system(size: 11))
                        Text("세션 \(folder.sessions)")
                            .font(.system(size: 9))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(Color.yellow.opacity(0.16)))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.yellow.opacity(0.45)))
                        Spacer(minLength: 0)
                    }
                }
                Text("한 폴더를 여럿이 고치고 있습니다. 넘겨도 갈라지지 않습니다.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
    }
}
