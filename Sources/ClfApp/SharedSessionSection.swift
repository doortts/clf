import SwiftUI
import ClfDesktop

/// 같은 대화를 여러 계정이 동시에 쓰는 것을 팝오버에 보여준다.
///
/// 한 폴더에 세션 여럿은 경고가 아니다. 사용자는 세션마다 워크트리를 갈라
/// 쓴다. 위험한 것은 서로 다른 계정의 창 둘이 한 대화에 같이 쓰는 것이고,
/// 지금은 그것을 doctor 를 돌려야만 안다.
@MainActor
final class SharedSessionModel: ObservableObject {
    @Published private(set) var shared: [SessionDuplicate.Live] = []
    /// 대화 id -> 제목. 개수만 보여주면 무엇인지 모른다.
    @Published private(set) var titles: [String: String] = [:]
    /// 훑은 시각. "몇 분 전" 은 이 시각 기준이라야 화면이 흔들리지 않는다.
    @Published private(set) var readAt = Date()
    /// 일부러 공유해 둔 대화. 문구가 달라진다.
    @Published private(set) var onPurpose: Set<String> = []

    /// 지금 뜬 경고가 공유해 둔 대화의 것인가.
    var isOnPurpose: Bool { shared.contains { onPurpose.contains($0.transcriptID) } }

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
        readAt = Date()
        let stores = SessionDuplicate.stores(inside: primary)
        // 방금 넘긴 대화는 참는다. 넘기기가 만든 겹침은 사용자가 아는 일이다
        let muted = (try? HandoffGrace())?.muted(now: readAt) ?? []
        // 공유해 둔 대화는 우리가 맞춰 준 활동을 뺀다. 안 빼면 동기화가
        // 경고를 만든다. docs/design/14-shared-session.md 6절
        let ledger = try? SharedSessions()
        onPurpose = Set(ledger?.all().keys ?? [:].keys)
        shared = SessionDuplicate.scanLive(stores: stores, now: readAt, muted: muted,
                                           mirrored: ledger?.mirrorStamps() ?? [:])
        // 제목은 겹친 대화 것만 읽는다. 열 때 한 번, 많아야 한두 개다
        titles = Dictionary(uniqueKeysWithValues: shared.map {
            ($0.transcriptID,
             SessionDuplicate.titles(ids: [$0.transcriptID]).first ?? SessionDuplicate.untitled)
        })
    }

    func title(_ id: String) -> String { titles[id] ?? SessionDuplicate.untitled }
}

/// 겹칠 때만 나타나는 묶음. 겹치는 일이 없으면 아무것도 그리지 않는다.
struct SharedSessionSection: View {
    @ObservedObject var model: SharedSessionModel
    /// 계정 uuid -> 이름. 어느 창이 쓰는 중인지 이름으로 말한다.
    var names: [String: String] = [:]

    var body: some View {
        if !model.shared.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("여러 계정이 같은 세션을 쓰는 중")
                    .captionStyle().foregroundStyle(.secondary)
                ForEach(model.shared) { live in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.title(live.transcriptID))
                            .subheadStyle(.semibold)
                            .lineLimit(1).truncationMode(.tail)
                        // 계정마다 언제까지 썼는지 적어야 사용자가 어느
                        // 창을 닫을지 고를 수 있다
                        ForEach(Array(live.owners.enumerated()),
                                id: \.offset) { _, sighting in
                            Text("- \(note(sighting))")
                                .captionStyle().foregroundStyle(.secondary)
                                .padding(.leading, 12)
                        }
                    }
                }
                // 경고만 있고 길이 없으면 사용자가 막힌다. 할 일을 같이 적는다
                Text(SessionDuplicate.problem(shared: model.isOnPurpose))
                    .captionStyle().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                Text(SessionDuplicate.advice(shared: model.isOnPurpose))
                    .captionStyle().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 위 계정 카드에 붙여 두면 카드의 꼬리처럼 읽힌다. 딴 얘기임을
            // 간격으로 말한다
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
    }

    /// "NAVER_TEAM_40 에서 7분 전까지 작업". 이름을 못 읽었으면 uuid 앞
    /// 8자로 부른다. DesktopReader 가 같은 방식으로 부른다.
    private func note(_ sighting: SessionDuplicate.Sighting) -> String {
        SessionDuplicate.workNote(
            account: names[sighting.account] ?? String(sighting.account.prefix(8)),
            wroteAt: sighting.lastActivityAt,
            now: model.readAt)
    }
}
