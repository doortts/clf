import SwiftUI
import ClflDesktop

/// 시안이 정한 치수. docs/design/ui-spec.html
enum Metrics {
    static let popoverWidth: CGFloat = 340
    static let popoverPadding: CGFloat = 14
    static let rowHeight: CGFloat = 28
    static let barHeight: CGFloat = 6

    /// 메뉴바 게이지. 스무 칸이라 한 칸이 5% 다.
    ///
    /// 칸 1pt = 2px, 안쪽 높이 3pt = 6px, 테두리 0.5pt = 1px, 줄 사이 2pt = 4px.
    /// 2배 화면에서 전부 정수 픽셀이다.
    ///
    /// 테두리는 줄마다 따로 긋고 등급색으로 칠한다. 그래서 **여기까지가 100%**
    /// 라는 것이 눈에 보인다. 안쪽은 이어진 막대다. 테두리가 끝을 알려주므로
    /// 칸을 갈라 그릴 이유가 없다.
    static let segSteps = 20
    static let segStepWidth: CGFloat = 1
    static let segRowHeight: CGFloat = 3
    static let segBorder: CGFloat = 0.5
    /// 줄 사이. 테두리를 각자 그으므로 그 사이를 띄운다.
    static let segRowGap: CGFloat = 2

    /// 게이지 바깥을 얼마나 어둡게 까나. 막대가 그 위에 떠 보이는 만큼.
    static let gaugeTrackDim = 0.25
    /// 1% 라도 있으면 보이게 주는 최소 폭. 끝이 곧아졌으니 크게 줄 이유가
    /// 없다. 넓게 주면 그만큼 값을 부풀려 보여준다.
    static let gaugeMinFill: CGFloat = 2

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

    /// 트랙을 채우는 막대 색. 라이트에서만 알약과 따로 간다.
    ///
    /// 어두운 팝오버에서는 알약색 하나로 충분했다. 밝은 팝오버에서는 그
    /// 색이 그대로 나오면서 정상 구간의 막대가 화면에서 제일 어두운
    /// 덩어리가 되고, 여유 구간의 초록은 트랙과 대비가 1.3 밖에 안 되어
    /// 어디까지 찼는지 안 보였다. 눈길을 끌지 않아야 할 쪽이 더 세게 튀는
    /// 뒤집힘이다. 숫자가 앉는 알약은 그대로 두고 막대만 바꾼다.
    /// docs/design/light-gauge-mockup.html B안
    /// **값이 시안보다 한 단 어둡다.** 팝오버 창이 반투명이라 칠한 색이
    /// 뒤쪽과 섞여 밝아진다. 실측으로 시안의 목표색(#12803a, #9a9aa0)이
    /// 화면에 나오는 지점까지 내렸다.
    func gaugeFill(dark: Bool) -> Color {
        guard !dark else { return gaugeTint }
        switch self {
        case .ample:  return Color(hex: 0x005c1f)
        case .normal: return Color(hex: 0x86868c)
        case .low, .empty: return gaugeTint
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
/// 스무 칸이므로 **한 칸이 5%** 다. 켤 칸 수는 방향 설정이 정한다.
/// 남은 용량은 올림이라 잔여 87% 가 18칸, 99% 는 스무 칸 전부다. 사용률은
/// 내림이라 1% 라도 남았으면 빈 칸 하나가 남는다. `GaugeDirection.litSteps`.
///
/// 테두리를 등급색으로 두르고 안쪽을 그만큼 채운다. 테두리가 100% 의 끝을
/// 알려주므로 안쪽은 이어진 막대로 두고 칸을 갈라 그리지 않는다.
struct SegmentGauge: View {
    let used: Int?
    let band: UsageBand?
    let direction: GaugeDirection
    var dark = true

    init(limit: UsageLimit?, direction: GaugeDirection, dark: Bool = true) {
        self.used = limit?.percentUsed
        self.band = limit?.band
        self.direction = direction
        self.dark = dark
    }

    init(used: Int?, band: UsageBand?, direction: GaugeDirection, dark: Bool = true) {
        self.used = used
        self.band = band
        self.direction = direction
        self.dark = dark
    }

    static var totalSteps: Int { Metrics.segSteps }

    static var width: CGFloat {
        CGFloat(Metrics.segSteps) * Metrics.segStepWidth + Metrics.segBorder * 2
    }
    static var height: CGFloat { Metrics.segRowHeight + Metrics.segBorder * 2 }

    var body: some View {
        let tint = band?.dotColor(dark: dark) ?? Color.secondary
        let off = Color.primary.opacity(dark ? 0.22 : 0.16)
        let lit = used.map { direction.litSteps(used: $0, total: Self.totalSteps) } ?? 0
        Canvas { ctx, size in
            let b = Metrics.segBorder
            ctx.stroke(Path(CGRect(origin: .zero, size: size).insetBy(dx: b / 2, dy: b / 2)),
                       with: .color(tint), lineWidth: b)

            let inner = CGRect(x: b, y: b, width: size.width - b * 2, height: size.height - b * 2)
            let filled = inner.width * CGFloat(lit) / CGFloat(Self.totalSteps)
            if filled > 0 {
                ctx.fill(Path(CGRect(x: inner.minX, y: inner.minY,
                                     width: filled, height: inner.height)),
                         with: .color(tint))
            }
            if filled < inner.width {
                ctx.fill(Path(CGRect(x: inner.minX + filled, y: inner.minY,
                                     width: inner.width - filled, height: inner.height)),
                         with: .color(off))
            }
        }
        .frame(width: Self.width, height: Self.height)
    }
}

/// 세 창을 세 줄로. 메뉴바가 이걸 쓴다.
///
/// 줄 사이를 벌린다. 붙여 두면 세 줄이 한 덩어리로 보여 어느 창이 어느
/// 줄인지 못 읽는다.
struct SegmentBlock: View {
    let org: OrgUsage
    let direction: GaugeDirection
    var dark = true

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.segRowGap) {
            if let spend = org.spend, org.limits.isEmpty {
                // Enterprise 는 창이 없다. 예산 한 줄만 그린다
                SegmentGauge(used: spend.percentUsed, band: spend.band,
                             direction: direction, dark: dark)
            } else {
                ForEach(LimitKind.allCases, id: \.self) { kind in
                    SegmentGauge(limit: org.limits[kind], direction: direction, dark: dark)
                }
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
    /// 화면에 적을 퍼센트. 방향은 설정이 정한다. 모르면 nil.
    let percent: Int?
    let band: UsageBand?
    var height: CGFloat = 18
    /// 숫자가 앉는 왼쪽 자리.
    var numberArea: CGFloat = 44
    /// 바깥 알약과 파낸 자리 사이.
    var trackInset: CGFloat = 2.5
    /// 파낸 자리와 채움 사이. 이게 없으면 가득 찼을 때 테두리가 사라져
    /// 100% 와 그냥 칠한 막대가 구별이 안 된다.
    var fillInset: CGFloat = 1.5

    init(limit: UsageLimit?, direction: GaugeDirection) {
        self.percent = limit.map { direction.displayPercent(used: $0.percentUsed) }
        self.band = limit?.band
    }

    init(spend: SpendUsage, direction: GaugeDirection) {
        self.percent = direction.displayPercent(used: spend.percentUsed)
        self.band = spend.band
    }

    /// 숫자 색. 등급이 정한다. 모르는 값은 바탕도 흐릿해서 기본색이 낫다.
    private var ink: Color {
        guard let band else { return .primary }
        return band.prefersLightInk ? .white : .black
    }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tint = band?.gaugeTint ?? Color.secondary.opacity(0.5)
        // 알약은 tint 로 그대로 그리고 막대만 따로 칠한다
        let fillTint = band?.gaugeFill(dark: scheme == .dark) ?? tint
        GeometryReader { geo in
            let trackWidth = max(0, geo.size.width - numberArea - trackInset)
            let trackHeight = height - trackInset * 2
            let boxWidth = max(0, trackWidth - fillInset * 2)
            let boxHeight = trackHeight - fillInset * 2

            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(tint)
                    // 바깥을 한 단 어둡게 깐다. 막대와 같은 색이면 막대가
                    // 배경에 잠겨 평평해 보인다. 색을 새로 정하지 않고
                    // 검정을 덮으므로 등급색이 무엇이든 같은 만큼 내려간다
                    Capsule().fill(Color.black.opacity(Metrics.gaugeTrackDim))
                    Capsule()
                        .frame(width: trackWidth, height: trackHeight)
                        .offset(x: numberArea)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()

                if let percent, percent > 0 {
                    // 오른쪽 끝은 곧게 끊는다. 둥글리면 그 곡선만큼 값이
                    // 뭉개져 보인다. 가득 찼을 때만 바깥 테를 따라 둥글어진다
                    Rectangle()
                        .fill(fillTint)
                        .frame(width: max(Metrics.gaugeMinFill,
                                          boxWidth * Double(percent) / 100),
                               height: boxHeight)
                        .frame(width: boxWidth, height: boxHeight, alignment: .leading)
                        .clipShape(Capsule())
                        .offset(x: numberArea + fillInset)
                }

                // 어두워진 바탕 위에서 읽히는 쪽으로. 노랑만 검정이 낫다
                Text(percent.map { "\($0)%" } ?? BarText.unknown)
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(ink)
                    .frame(width: numberArea, height: height)
            }
        }
        .frame(height: height)
    }
}
