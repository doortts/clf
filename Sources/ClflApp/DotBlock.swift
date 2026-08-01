import SwiftUI
import ClflDesktop

/// 시안이 정한 치수. docs/design/ui-spec.html
enum Metrics {
    static let popoverWidth: CGFloat = 340
    static let popoverPadding: CGFloat = 14
    static let rowHeight: CGFloat = 28
    static let barHeight: CGFloat = 6

    /// 메뉴바 게이지. 사각형 5개에 사각형마다 세로선 4개, 선 하나가 5% 다.
    /// 사각형 5x3pt, 사이 1.5pt, 선 0.5pt 에 간격 1pt. 전체 폭 31pt.
    static let segSquare = CGSize(width: 5, height: 3)
    static let segSquareGap: CGFloat = 1.5
    static let segLineWidth: CGFloat = 0.5
    static let segLinePitch: CGFloat = 1
    static let segSquares = 5
    static let segLinesPerSquare = 4
    /// 줄 사이. 붙여 두면 세 줄이 한 덩어리로 보인다.
    static let segRowGap: CGFloat = 2

    /// 팝오버 막대. 디더 격자 2pt, 네 줄이면 높이 8pt.
    ///
    /// 시안은 6pt 라고 적었는데 디더로 그리면 세 줄은 선처럼 얇아 보인다.
    /// 질감이 보여야 게이지로 읽힌다. 85칸이면 폭 170pt.
    static let ditherPitch: CGFloat = 2
    static let ditherRows = 4
    static let ditherColumns = 85
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

    /// 등급색으로 채운 알약 위에 얹을 글자색.
    var onFillColor: Color {
        switch self {
        case .ample, .low: return .black       // 초록과 노랑은 밝다
        case .empty:       return .white
        case .normal:      return .primary
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

/// 눈금 게이지 한 줄.
///
/// 사각형 다섯에 사각형마다 세로선 넷. 스무 칸이므로 **선 하나가 5%** 다.
/// 5% 단위로 **올림**한다. 89% 는 18칸, 83% 는 17칸, 99% 는 스무 칸 전부다.
///
/// 실제 크기에서는 선 넷이 붙어 사각형 하나로 읽힌다. 그게 의도다. 확대하면
/// 눈금이 갈려 값이 어디서 끊겼는지 보인다.
struct SegmentGauge: View {
    let limit: UsageLimit?
    var dark = true

    static var totalSteps: Int { Metrics.segSquares * Metrics.segLinesPerSquare }
    /// 한 칸이 몇 퍼센트인가. 스무 칸이면 5% 다.
    static var stepPercent: Double { 100 / Double(totalSteps) }

    static func steps(for remaining: Int) -> Int {
        guard remaining > 0 else { return 0 }
        return min(totalSteps, Int((Double(remaining) / stepPercent).rounded(.up)))
    }

    static var width: CGFloat {
        CGFloat(Metrics.segSquares) * Metrics.segSquare.width
            + CGFloat(Metrics.segSquares - 1) * Metrics.segSquareGap
    }

    var body: some View {
        let on = limit?.band.dotColor(dark: dark) ?? Color.secondary
        let off = Color.primary.opacity(dark ? 0.22 : 0.16)
        let lit = Self.steps(for: limit?.percentRemaining ?? 0)
        // 선 넷과 사이 셋을 사각형 안에 가운데로. (5 - (4*0.5 + 3*0.5)) / 2 = 0.75
        let inset = (Metrics.segSquare.width
            - (CGFloat(Metrics.segLinesPerSquare) * Metrics.segLineWidth
               + CGFloat(Metrics.segLinesPerSquare - 1)
                 * (Metrics.segLinePitch - Metrics.segLineWidth))) / 2
        Canvas { ctx, _ in
            for square in 0..<Metrics.segSquares {
                let x0 = CGFloat(square) * (Metrics.segSquare.width + Metrics.segSquareGap) + inset
                for line in 0..<Metrics.segLinesPerSquare {
                    let index = square * Metrics.segLinesPerSquare + line
                    let x = x0 + CGFloat(line) * Metrics.segLinePitch
                    ctx.fill(Path(CGRect(x: x, y: 0, width: Metrics.segLineWidth,
                                         height: Metrics.segSquare.height)),
                             with: .color(index < lit ? on : off))
                }
            }
        }
        .frame(width: Self.width, height: Metrics.segSquare.height)
    }
}

/// 세 창을 세 줄로. 메뉴바가 이걸 쓴다.
///
/// 줄 사이를 벌린다. 붙여 두면 세 줄이 한 덩어리로 보여 어느 창이 어느
/// 줄인지 못 읽는다.
struct SegmentBlock: View {
    let limits: [LimitKind: UsageLimit]
    var dark = true

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.segRowGap) {
            ForEach(LimitKind.allCases, id: \.self) { kind in
                SegmentGauge(limit: limits[kind], dark: dark)
            }
        }
        .fixedSize()
    }
}

/// 레트로 디더 게이지.
///
/// 칸을 떨어뜨려 놓지 않고 막대 하나 안에서 **점의 밀도**로 채움을 표현한다.
/// 채운 쪽은 촘촘하고 빈 쪽은 성기다.
///
/// 격자는 2pt = 4px, 채운 점 1.5pt = 3px, 빈 점 0.5pt = 1px. 전부 2배 화면에서
/// 정수 픽셀이라 번지지 않는다. 점을 칸 한가운데 두면 0.25pt 같은 값이 나와
/// 다시 흐려지므로, 채운 점은 칸 왼쪽 위에 붙이고 빈 점만 안쪽 픽셀에 놓는다.
struct RetroBar: View {
    let limit: UsageLimit?
    var pitch = Metrics.ditherPitch
    var rows = Metrics.ditherRows
    var columns = Metrics.ditherColumns
    var dark = true

    private var filled: Int {
        guard let limit, limit.percentRemaining > 0 else { return 0 }
        // 1% 라도 남았으면 한 칸은 켠다. 0 으로 그리면 소진과 구별이 안 된다
        return max(1, Int((Double(columns) * Double(limit.percentRemaining) / 100).rounded()))
    }

    var body: some View {
        let on = limit?.band.dotColor(dark: dark) ?? Color.secondary
        let off = Color.primary.opacity(dark ? 0.20 : 0.15)
        let cut = filled
        Canvas { ctx, _ in
            let big: CGFloat = 1.5, small: CGFloat = 0.5
            for row in 0..<rows {
                let y = CGFloat(row) * pitch
                for col in 0..<columns {
                    let x = CGFloat(col) * pitch
                    if col < cut {
                        ctx.fill(Path(CGRect(x: x, y: y, width: big, height: big)),
                                 with: .color(on))
                    } else {
                        ctx.fill(Path(CGRect(x: x + small, y: y + small,
                                             width: small, height: small)),
                                 with: .color(off))
                    }
                }
            }
        }
        .frame(width: pitch * CGFloat(columns), height: pitch * CGFloat(rows))
    }
}

/// 테두리 안에 채우는 게이지. 팝오버가 쓴다.
///
/// 바깥은 등급색 테두리만 두른 알약, 안쪽은 그만큼 채운 알약이다. 사이에
/// 틈을 둬서 채운 양과 전체가 따로 읽힌다.
struct CapsuleGauge: View {
    let limit: UsageLimit?
    var height: CGFloat = 13
    var stroke: CGFloat = 1.5
    /// 테두리와 채움 사이. 이게 없으면 가득 찼을 때 테두리가 사라져 보인다.
    var inset: CGFloat = 2

    var body: some View {
        let band = limit?.band
        let tint = band?.fillColor ?? .secondary
        GeometryReader { geo in
            let inner = geo.size.width - (stroke + inset) * 2
            let ratio = Double(limit?.percentRemaining ?? 0) / 100
            ZStack(alignment: .leading) {
                Capsule().strokeBorder(tint.opacity(limit == nil ? 0.35 : 1), lineWidth: stroke)
                if let limit, limit.percentRemaining > 0 {
                    Capsule()
                        .fill(tint)
                        // 1% 라도 남았으면 보이게 한다. 0 으로 그리면 소진과 같아진다
                        .frame(width: max(height - (stroke + inset) * 2, inner * ratio),
                               height: height - (stroke + inset) * 2)
                        .padding(.leading, stroke + inset)
                }
            }
        }
        .frame(height: height)
    }
}

/// 잔여를 담은 알약. 게이지 왼쪽에 붙는다.
struct PercentPill: View {
    let limit: UsageLimit?
    var width: CGFloat = 46
    var height: CGFloat = 13

    var body: some View {
        let band = limit?.band
        Text(limit.map { "\($0.percentRemaining)%" } ?? BarText.unknown)
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .foregroundStyle(band?.onFillColor ?? .secondary)
            .frame(width: width, height: height)
            .background(
                Capsule().fill(band.map { $0 == .normal
                    ? Color.primary.opacity(0.12) : $0.fillColor } ?? Color.primary.opacity(0.08))
            )
    }
}
