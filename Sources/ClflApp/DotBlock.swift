import SwiftUI
import ClflDesktop

/// 시안이 정한 치수. docs/design/ui-spec.html
enum Metrics {
    static let popoverWidth: CGFloat = 340
    static let popoverPadding: CGFloat = 14
    static let rowHeight: CGFloat = 28
    static let barHeight: CGFloat = 6

    /// 메뉴바 블록. 칸 2pt, 간격 1pt, 17칸이면 폭 50pt 로 시안의 52pt 에 가깝고
    /// 모든 좌표가 정수라 2배 화면에서 픽셀에 딱 맞는다.
    static let barCell = CGSize(width: 2, height: 2)
    static let barGap: CGFloat = 1
    static let barColumns = 17

    /// 팝오버 막대는 6pt. 칸 4x6, 간격 2pt, 29칸이면 폭 172pt.
    static let popoverCell = CGSize(width: 4, height: 6)
    static let popoverGap: CGFloat = 2
    static let popoverColumns = 29
}

extension UsageBand {
    /// 도트 전용 색.
    ///
    /// 시스템 색을 그대로 못 쓴다. 1pt 짜리 점은 안티에일리어싱에 색이 씻겨서
    /// 면으로 칠할 때 멀쩡하던 값이 점으로는 흐려 보인다. 라이트 모드 경고색이
    /// 노랑이 아니라 앰버인 것도 그래서다. systemYellow 는 흰 바탕에서 대비가
    /// 2.1 이라 점으로 그리면 거의 안 보인다.
    func dotColor(dark: Bool) -> Color {
        switch self {
        case .ample:  return dark ? Color(hex: 0x3ce16b) : Color(hex: 0x17993f)
        case .low:    return dark ? Color(hex: 0xffe500) : Color(hex: 0xbf7f00)
        case .empty:  return dark ? Color(hex: 0xff4a3d) : Color(hex: 0xe02017)
        case .normal: return .primary
        }
    }

    /// 면으로 칠할 때는 시스템 색을 그대로 쓴다.
    var fillColor: Color {
        switch self {
        case .ample:  return .green
        case .low:    return .yellow
        case .empty:  return .red
        case .normal: return .primary
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

/// 잔여를 칸으로 그린 한 줄.
///
/// **칸 크기와 간격을 정수 포인트로 고정한다.** 폭을 먼저 정하고 칸 수로
/// 나누면 칸이 2.89pt 같은 값이 되어 픽셀 격자에 안 맞고, 그러면 안티에일리어싱에
/// 번져서 또렷한 사각형이 아니라 뭉개진 점처럼 보인다.
///
/// 채운 칸을 빈 칸보다 굵게 그린다. 색보다 무게 차이가 먼저 읽힌다.
struct DotRow: View {
    let limit: UsageLimit?
    /// 칸 하나의 크기. 정수라야 또렷하다.
    var cell = CGSize(width: 2, height: 2)
    var gap: CGFloat = 1
    var columns = 17
    var dark = true

    /// 빈 칸은 높이만 줄인다. 폭까지 줄이면 격자가 흔들려 보인다.
    private var emptyHeight: CGFloat { max(1, (cell.height / 2).rounded()) }

    private var filled: Int {
        guard let limit, limit.percentRemaining > 0 else { return 0 }
        // 1% 라도 남았으면 한 칸은 켠다. 0 으로 그리면 소진과 구별이 안 된다
        return max(1, Int((Double(columns) * Double(limit.percentRemaining) / 100).rounded()))
    }

    var body: some View {
        let on = limit?.band.dotColor(dark: dark) ?? Color.secondary
        let off = Color.primary.opacity(dark ? 0.22 : 0.16)
        HStack(spacing: gap) {
            ForEach(0..<columns, id: \.self) { i in
                Rectangle()
                    .fill(i < filled ? on : off)
                    .frame(width: cell.width, height: i < filled ? cell.height : emptyHeight)
            }
        }
        .frame(height: cell.height)
    }
}

/// 세 창을 세 줄로. 메뉴바가 이걸 쓴다.
struct DotBlock: View {
    let limits: [LimitKind: UsageLimit]
    var dark = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(LimitKind.allCases, id: \.self) { kind in
                DotRow(limit: limits[kind], cell: Metrics.barCell, gap: Metrics.barGap,
                       columns: Metrics.barColumns, dark: dark)
            }
        }
        .fixedSize()
    }
}
