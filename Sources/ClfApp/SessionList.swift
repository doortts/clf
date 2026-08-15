import SwiftUI
import ClfDesktop

/// 세션 목록 한 틀. **두 탭이 같은 것을 쓴다.**
///
/// 목록이 보여주는 것은 탭마다 다르다. 작업 이전은 데스크톱 앱의 대화 레코드를,
/// 자동 재개는 CLI 의 세션 기록을 올린다. 그래도 **고르는 화면으로서는 같은
/// 것**이라 틀이 갈라지면 안 된다. 실제로 갈라져 있었고, 그동안 자동 재개
/// 목록만 스크롤 막대가 사라졌다.
///
/// 개수 줄까지 여기서 그린다. 목록과 그 위 한 줄은 한 덩어리라, 떼어 두면
/// 한쪽만 고쳐서 또 갈라진다.
struct SessionList<Item: Identifiable, Row: View>: View {
    /// 개수 줄에 쓰는 이름. `세션`, `CLI 세션`.
    ///
    /// 두 목록은 출처가 달라서 이름도 달라야 한다. 같은 것의 다른 셈으로
    /// 읽히면 안 된다. docs/design/16-auto-resume.md 6절
    let noun: String
    let items: [Item]
    /// 목록이 비었을 때 그 자리에 적을 말. 비는 이유가 탭마다 다르다.
    let emptyText: String
    @ViewBuilder let row: (Item) -> Row

    /// 상자급 반지름. 목록도 상자다.
    private static var radius: CGFloat { 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            count
            list
        }
    }

    /// 목록에 몇 개가 있는지. 화면에 셋만 보이면 그게 전부인지 알 수 없다.
    ///
    /// 고른 개수는 안 적는다. 아래 단추가 이미 `2개 옮기기` 라고 말한다.
    /// 비었을 때는 안 적는다. `0개` 와 목록 한가운데 안내가 같은 말을 두 번 한다.
    @ViewBuilder private var count: some View {
        if !items.isEmpty {
            Text("\(noun) \(items.count)개")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().opacity(0.4) }
                    row(item)
                }
            }
            // 넘칠 때는 막대를 계속 보여준다
            .background(AlwaysVisibleScrollers())
        }
        .frame(height: Metrics.listHeight)
        // 검정 덮기 대신 라벨색 퍼센트. 라이트에서도 같은 만큼 가라앉는다
        .background(RoundedRectangle(cornerRadius: Self.radius).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Self.radius).stroke(Color.primary.opacity(0.10)))
        .overlay {
            if items.isEmpty {
                Text(emptyText)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

/// 목록 줄 하나.
///
/// `onTapGesture` 는 스크롤 뷰 안에서 클릭을 놓친다. 단추로 만들면 키보드와
/// 보이스오버도 따라온다.
struct SessionRow: View {
    /// 고르는 규칙. **모양이 규칙을 말한다.**
    ///
    /// 눌러보기 전에 여러 개를 고를 수 있는지 알아야 한다. 작업 이전은 여러
    /// 개를 옮기고 자동 재개는 하나만 이어 돌린다.
    enum Pick {
        case many
        case one

        func glyph(on: Bool) -> String {
            switch self {
            case .many: return on ? "checkmark.square.fill" : "square"
            case .one:  return on ? "largecircle.fill.circle" : "circle"
            }
        }
    }

    let pick: Pick
    let on: Bool
    let title: String
    /// 제목 아래 한 줄. **색은 부르는 쪽이 정해서 넘긴다.**
    ///
    /// 작업 이전은 폴더와 경고를 한 줄에 같이 적고 경고에만 색을 준다. 여기서
    /// 색을 덮으면 폴더까지 그 색이 된다.
    let detail: Text
    /// 오른쪽 끝 시각. 목록에서 차례를 가늠하는 값이다.
    let at: Date?
    let label: String
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Image(systemName: pick.glyph(on: on))
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12)).lineLimit(1)
                    detail.font(.system(size: 10)).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(BarText.since(at))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// 목록이 넘치면 스크롤 막대를 계속 보여준다.
///
/// `.scrollIndicators(.visible)` 로는 안 된다. 시스템 설정의 "스크롤 막대
/// 보기" 기본값이 "스크롤할 때" 라서 SwiftUI 의 요청보다 앞선다. 이 창
/// 하나에서만 뒤집으려면 감싸는 `NSScrollView` 를 찾아 legacy 로 바꾼다.
/// legacy 막대는 겹치지 않고 자리를 차지하므로 안 넘칠 때는 안 보인다.
struct AlwaysVisibleScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        // 뷰 계층은 makeNSView 시점에 아직 안 붙어 있다. 다음 사이클에 찾는다
        DispatchQueue.main.async {
            var view: NSView? = probe
            while let v = view, !(v is NSScrollView) { view = v.superview }
            guard let scroll = view as? NSScrollView else { return }
            scroll.scrollerStyle = .legacy
            scroll.autohidesScrollers = true
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
