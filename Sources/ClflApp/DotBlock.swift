import SwiftUI
import ClflDesktop

/// 시안이 정한 치수. docs/design/ui-spec.html
enum Metrics {
    static let popoverWidth: CGFloat = 340
    static let popoverPadding: CGFloat = 14
    static let rowHeight: CGFloat = 28
    static let barHeight: CGFloat = 6

    /// 메뉴바 블록 52x9pt, 세 줄.
    static let blockWidth: CGFloat = 52
    static let blockHeight: CGFloat = 9
    static let dotColumns = 18
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

/// 잔여를 점으로 그린 한 줄.
///
/// **채운 점을 빈 점보다 굵게 그린다.** 색보다 무게 차이가 먼저 읽힌다.
struct DotRow: View {
    let limit: UsageLimit?
    var columns = Metrics.dotColumns
    var width = Metrics.blockWidth
    var dark = true

    private var filled: Int {
        guard let limit else { return 0 }
        // 1% 라도 남았으면 점 하나는 켠다. 0 으로 그리면 소진과 구별이 안 된다
        let exact = Double(columns) * Double(limit.percentRemaining) / 100
        return limit.percentRemaining > 0 ? max(1, Int(exact.rounded())) : 0
    }

    var body: some View {
        Canvas { ctx, size in
            let pitch: CGFloat = size.width / CGFloat(columns)
            let on = limit?.band.dotColor(dark: dark) ?? .secondary
            let off = Color.primary.opacity(dark ? 0.22 : 0.16)
            for i in 0..<columns {
                let big = i < filled
                let d: CGFloat = big ? size.height : size.height * 0.62
                let rect = CGRect(x: pitch * CGFloat(i) + (pitch - d) / 2,
                                  y: (size.height - d) / 2, width: d, height: d)
                ctx.fill(Path(ellipseIn: rect), with: .color(big ? on : off))
            }
        }
        .frame(width: width, height: max(2, width / CGFloat(columns) * 0.9))
    }
}

/// 세 창을 세 줄로. 메뉴바가 이걸 쓴다.
struct DotBlock: View {
    let limits: [LimitKind: UsageLimit]
    var dark = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(LimitKind.allCases, id: \.self) { kind in
                DotRow(limit: limits[kind], dark: dark)
            }
        }
        .frame(width: Metrics.blockWidth)
    }
}
