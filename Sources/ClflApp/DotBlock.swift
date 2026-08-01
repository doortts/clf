import SwiftUI
import ClflDesktop

/// 시안이 정한 치수. docs/design/ui-spec.html
enum Metrics {
    static let popoverWidth: CGFloat = 340
    static let popoverPadding: CGFloat = 14
    static let rowHeight: CGFloat = 28
    static let barHeight: CGFloat = 6

    /// 메뉴바 게이지. 사각형 5개에 사각형마다 세로선 4개, 선 하나가 5% 다.
    ///
    /// **선끼리는 붙이고 사각형끼리만 뗀다.** 선 사이에 틈을 두면 실제 크기에서
    /// 사각형이 안 보이고 잔금만 보인다. 선 1pt 넷이 붙어 4pt 사각형이 되고,
    /// 사각형 사이만 1pt 띄운다. 전체 폭 24pt.
    ///
    /// 처음에는 사각형 5pt 에 선 0.5pt, 간격 1pt 였다. 안쪽 여백이 0.75pt
    /// = 1.5px 라 선이 반 픽셀에 걸쳐 뭉개졌고, 사각형 사이만 벌어져 보였다.
    static let segSquare = CGSize(width: 4, height: 3)
    static let segSquareGap: CGFloat = 1
    static let segLineWidth: CGFloat = 1
    /// 선 사이에 틈이 없다. 값이 어디서 끊겼는지는 채운 폭으로 드러난다.
    static let segLinePitch: CGFloat = 1
    static let segSquares = 5
    static let segLinesPerSquare = 4
    /// 줄 사이. 붙여 두면 세 줄이 한 덩어리로 보인다.
    /// 1.5pt = 3px. 2배 화면에서 정수 픽셀이다.
    static let segRowGap: CGFloat = 1.5

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

    /// 게이지 알약을 칠할 색. 정상 구간은 눈길을 끌지 않아야 하므로
    /// 등급색 대신 회색이다.
    var gaugeTint: Color {
        self == .normal ? .secondary : fillColor
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

/// 숫자와 게이지가 한 알약 안에 있다. 팝오버가 쓴다.
///
/// ```
/// +--------------------------------------------+
/// |  88%   ( ==================------- )       |
/// +--------------------------------------------+
/// ```
///
/// 바깥 알약을 등급색으로 꽉 채우고 오른쪽 안쪽을 **파낸다.** 파낸 자리 안에
/// 다시 등급색으로 채우고, 숫자는 왼쪽 등급색 위에 그대로 얹는다.
///
/// 파낸 자리를 배경색으로 칠하지 않고 `destinationOut` 으로 뚫는다. 팝오버
/// 배경은 단색이 아니라 vibrancy 재질이라 색으로 흉내내면 어긋난다.
struct UsageGauge: View {
    let limit: UsageLimit?
    var height: CGFloat = 18
    /// 숫자가 앉는 왼쪽 자리.
    var numberArea: CGFloat = 44
    /// 바깥 알약과 파낸 자리 사이.
    var trackInset: CGFloat = 2.5
    /// 파낸 자리와 채움 사이. 이게 없으면 가득 찼을 때 테두리가 사라져
    /// 100% 와 그냥 칠한 막대가 구별이 안 된다.
    var fillInset: CGFloat = 1.5

    var body: some View {
        let tint = limit?.band.gaugeTint ?? Color.secondary.opacity(0.5)
        GeometryReader { geo in
            let trackWidth = max(0, geo.size.width - numberArea - trackInset)
            let trackHeight = height - trackInset * 2
            let boxWidth = max(0, trackWidth - fillInset * 2)
            let boxHeight = trackHeight - fillInset * 2

            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(tint)
                    Capsule()
                        .frame(width: trackWidth, height: trackHeight)
                        .offset(x: numberArea)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()

                if let limit, limit.percentRemaining > 0 {
                    // 1% 라도 남았으면 보이게 최소 폭을 준다
                    Capsule()
                        .fill(tint)
                        .frame(width: max(boxHeight,
                                          boxWidth * Double(limit.percentRemaining) / 100),
                               height: boxHeight)
                        .offset(x: numberArea + fillInset)
                }

                // 글자는 전부 검정. 노랑 위 흰 글자가 안 보인다
                Text(limit.map { "\($0.percentRemaining)%" } ?? BarText.unknown)
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .frame(width: numberArea, height: height)
            }
        }
        .frame(height: height)
    }
}
