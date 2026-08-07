import SwiftUI
import ClfDesktop

/// 시안이 정한 치수. docs/design/ui-spec.html
enum Metrics {
    static let popoverWidth: CGFloat = 340
    static let popoverPadding: CGFloat = 14
    static let rowHeight: CGFloat = 28
    static let barHeight: CGFloat = 6

    // MARK: macOS 27 UI Kit 실측값
    //
    // 킷의 컴포넌트를 하나씩 골라 읽은 값이다. 짐작한 값이 아니므로 여기 모아
    // 두고 화면 쪽에서는 이 상수만 쓴다.
    // docs/design/popover-hig27-applied-mockup.html

    /// 손으로 그리는 상자를 시스템 단추와 같은 높이로 앉힌다.
    ///
    /// 킷은 푸시 버튼을 높이 24, 좌우 16 으로 적는다. **그런데 이 OS 의 시스템
    /// 단추는 그 높이가 안 나온다.** `.bordered` 를 재 보면 mini 17, small 17,
    /// regular 20, large 28 이고 24 는 어느 크기에도 없다. frame 으로 24 를
    /// 줘도 베젤은 20 만 그리고 남은 4 는 빈 공기다.
    ///
    /// 그래서 킷 숫자가 아니라 **시스템 단추 실측값**을 따른다. 한 줄에 단추와
    /// 상자가 나란히 서는 자리라 둘이 같은 높이인 것이 킷 숫자를 맞추는 것보다
    /// 중요하다. 킷 값은 macOS 26 이 유리 단추를 주면 그때 다시 본다.
    static let controlHeight: CGFloat = 20
    static let controlPadding: CGFloat = 12
    /// 모서리는 킷 값 그대로다. 이건 시스템과 어긋나지 않는다.
    static let controlRadius: CGFloat = 6
    /// 팝오버 본체. Popover / Fill + Shadow.
    ///
    /// 창 모서리 자체는 MenuBarExtra 가 그리므로 우리가 못 바꾼다. 안쪽
    /// 반지름을 이 값에서 파생시키는 데만 쓴다.
    static let popoverRadius: CGFloat = 20
    /// 상자급. 팝오버 모서리에서 여백을 뺀 동심값이다.
    ///
    /// 시안은 8 이라고 적었는데 그건 여백을 12 로 잡은 계산이었다. 실제 여백은
    /// 14 라 6 이 맞고, 마침 킷의 푸시 버튼 모서리와 같은 값이다.
    static let boxRadius: CGFloat = popoverRadius - popoverPadding
    /// 배지와 세그먼트 칸. _Segment - Selectable.
    static let badgeRadius: CGFloat = 5
    /// 배지 높이. 4의 배수 격자에 앉힌다.
    static let badgeHeight: CGFloat = 16

    /// 막대의 간격 셋.
    ///
    /// 넓어 보이던 원인은 간격이 아니라 열에 남는 빈자리였다. 열 폭을 가장 긴
    /// 글자(`23h` 19.00, `100%` 29.48)에 못박아 두니 짧은 줄마다 7pt 씩 비었다.
    /// 열은 `BarGlyph` 로 계정마다 재서 정하고(빈자리 14pt 회수), 간격은 여기서
    /// 한 단 조인다(8.5 -> 5.5pt). 계정당 102.6 -> 85.6pt 다.
    /// docs/design/bar-compact-mockup.html C안
    /// 코드와 숫자 열, 숫자 열과 게이지 사이.
    static let barGap: CGFloat = 2
    /// 라벨과 숫자 사이. **이것만 조이지 않는다.** 열 폭이 글자에 딱 맞아서
    /// 여기까지 줄이면 `3h95%` 처럼 붙어 읽힌다. 예전에는 열에 남던 빈자리가
    /// 이 간격을 대신하고 있었다.
    static let barTagGap: CGFloat = 3
    /// 계정 사이.
    static let barOrgGap: CGFloat = 6

    // MARK: 글자. Text styles 의 크기
    //
    // 킷의 짝은 Body 13/16, Callout 12/15, Subheadline 11/14, Caption 10/13 이다.
    // **줄 높이를 우리가 손댈 일이 없다.** 재 보면 SwiftUI 의 기본 줄 상자가
    // 10pt -> 13.00, 11 -> 14.00, 12 -> 15.00, 13 -> 16.00 으로 이미 킷 값과
    // 같다. lineSpacing 으로 보정하려 했던 것은 없는 문제를 고치는 짓이었다.
    // 크기만 여기 모아 두고 줄 높이는 시스템에 맡긴다.
    static let bodySize: CGFloat = 13
    static let calloutSize: CGFloat = 12
    static let subheadSize: CGFloat = 11
    static let captionSize: CGFloat = 10

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
    /// 정상 등급은 어두운 쪽에서 연한 흰색, 밝은 쪽에서 회색이다.
    ///
    /// `.primary` 로 두면 안 된다. 흰 바탕에서 검정 1pt 점은 너무 세게 튀어서
    /// 정상 등급이 눈길을 끌지 않는다는 뜻을 잃는다.
    /// docs/design/band-normal-white-mockup.html A안
    ///
    /// **밝은 쪽 빨강은 한 단 어둡다.** 라이트 값들은 흰 팝오버 기준으로 고른
    /// 것인데 메뉴바는 벽지가 반투명하게 비쳐서 순백보다 어둡게 나온다. 실측한
    /// 흰 메뉴바가 L* 90.6 이고 그 위에서 예전 값(`#e02017`)은 대비가 3.73 뿐이라
    /// 10pt 글자 기준(4.5)에 못 미쳤다. L* 을 48 에서 35 로 내리면 6.05 가 되고,
    /// 밝은 하늘색 벽지처럼 흰색보다 어두운 바탕에서도 2.76 에서 4.48 로 오른다.
    /// 채도는 68 로 남아서 여전히 빨강으로 읽힌다.
    /// docs/design/menubar-red-strain.html
    func dotColor(dark: Bool) -> Color {
        switch self {
        case .ample:  return dark ? Color(hex: 0x3ce16b) : Color(hex: 0x17993f)
        case .low:    return dark ? Color(hex: 0xffe500) : Color(hex: 0xbf7f00)
        case .empty:  return dark ? Color(hex: 0xff4a3d) : Color(hex: 0xa3190f)
        case .normal: return dark ? Color(hex: 0xe5e5ea) : Color(hex: 0x86868c)
        }
    }

    /// 게이지 알약을 칠할 색. 정상 구간은 눈길을 끌지 않아야 하므로
    /// 등급색 대신 무채색이다.
    var gaugeTint: Color {
        self == .normal ? .secondary : fillColor
    }

    /// 팝오버 알약. **어두운 쪽과 밝은 쪽이 서로 뒤집혀 있다.**
    ///
    /// 어두운 팝오버는 알약이 밝고 숫자가 검정이다. 정상 등급만 여기서
    /// 갈리는데, 연한 흰색이 회색보다 두 배 또렷하다(대비 11.9 대 6.0).
    /// docs/design/band-normal-white-mockup.html A안
    ///
    /// 밝은 팝오버는 알약이 어둡고 숫자가 흰색이다. 예전에는 이쪽도 알약이
    /// 밝고 막대만 어두웠는데, 그러면 한 줄 안에서 밝은 알약이 어두운 막대를
    /// 감싸는 모양이 되어 막대가 파인 홈처럼 읽혔다. 알약과 막대의 색을
    /// 맞바꿔서 어두운 알약 위에 밝은 막대가 얹히게 한다.
    /// docs/design/light-gauge-invert-mockup.html B안
    func gaugePill(dark: Bool) -> Color {
        guard !dark else { return self == .normal ? Color(hex: 0xe5e5ea) : gaugeTint }
        switch self {
        case .ample:  return Color(hex: 0x12803a)
        case .low:    return Color(hex: 0x8f6000)
        case .empty:  return Color(hex: 0xa3190f)
        case .normal: return Color(hex: 0x6e6e72)
        }
    }

    /// 트랙을 채우는 막대 색. 라이트에서만 알약과 따로 간다.
    ///
    /// 어두운 팝오버에서는 알약색 하나로 충분하다. 밝은 팝오버에서는 알약이
    /// 어두워졌으므로 막대가 밝은 쪽을 맡는다. 주의와 소진은 시스템 색을
    /// 그대로 쓰고 여유와 정상만 값을 박는다.
    /// docs/design/light-gauge-invert-mockup.html B안
    func gaugeFill(dark: Bool) -> Color {
        // 정상 등급은 어두운 쪽에서도 값을 박는다. .secondary 는 재질 위에서
        // 흐려서 어디까지 찼는지 안 보였다
        guard !dark else { return self == .normal ? Color(hex: 0xe5e5ea) : gaugeTint }
        switch self {
        case .ample:  return Color(hex: 0x34c759)
        case .normal: return Color(hex: 0xaeaeb2)
        case .low, .empty: return gaugeTint
        }
    }

    /// 면으로 칠할 때는 시스템 색을 그대로 쓴다. 팝오버 배지가 쓴다.
    var fillColor: Color {
        switch self {
        case .ample:  return .green
        case .low:    return .yellow
        case .empty:  return .red
        case .normal: return .primary
        }
    }

    /// 막대의 숫자 색. 눈금과 같은 값을 쓴다.
    ///
    /// 시스템 색(`.green` 등)은 1pt 점에서 씻기는 것과 같은 이유로 구운 이미지의
    /// 작은 글자에서도 흐리다. 눈금이 이미 그 보정을 갖고 있으니 같이 쓴다.
    func barTextColor(dark: Bool) -> Color { dotColor(dark: dark) }
}

/// 주간 Fable 창의 여유 색. 초록 대신 파랑이다.
///
/// 게이지 색은 남은 용량 등급이 정한다. 그래서 세 창이 다 여유면 세 줄이 같은
/// 초록이었다. 셋째 줄만 파랑으로 빼면 창이 색으로 갈린다.
///
/// 처음에는 민트였는데 1pt 눈금에서 채도가 씻겨 정상 등급의 연한 흰색으로
/// 읽혔다. 파랑은 흰색과의 거리를 청록만큼 못 벌리지만(42.8 대 52.0) 지금
/// 값보다는 낫고, 팝오버와 막대가 같은 색이 된다.
///
/// **여유 구간에서만 덮는다.** 15% 아래로 떨어지면 노랑, 5% 아래면 빨강으로
/// 돌아간다. 그러지 않으면 같은 색이 창을 말하다가 등급을 말하는 두 겹 규칙이
/// 된다. 브랜드 색(클레이)을 안 쓴 이유는 그 색이 노랑과 빨강 사이에 앉아서
/// 여유 52% 가 위험으로 읽히기 때문이다.
/// docs/design/fable-hue-mockup.html
enum FableTint {
    /// 이 창만 색을 바꾼다.
    static let kind = LimitKind.weeklyScoped

    /// 눈금 게이지. **여기만 파랑이다.**
    ///
    /// 1pt 눈금에서는 채도가 안티에일리어싱에 씻겨서 밝기만 남는다. 밝은 청록
    /// (`0x5ee7de`, 채도 39.6)이 정상 등급의 연한 흰색으로 읽혔다.
    ///
    /// 연파랑은 채도가 더 낮다. sRGB 에서 파랑 원색의 밝기 기여가 7% 뿐이라
    /// 파랑을 밝게 만들려면 빨강과 초록을 섞어야 하고 섞는 만큼 채도가 떨어진다.
    /// 그래서 흰색과의 거리는 청록만큼 못 벌린다(42.8 대 52.0). 연파랑 중
    /// 채도가 가장 높은 값을 골랐고, 포커스 밑줄 파랑과는 아직 갈린다(51.3).
    ///
    /// 밝은 쪽은 대비를 우선한다. 흰 메뉴바에서 5.29 이고 밑줄의 라이트 값
    /// (`0x007aff`)과 거리가 25.7 로 후보 중 가장 멀다.
    /// docs/design/fable-lightblue-mockup.html
    static func dot(dark: Bool) -> Color {
        dark ? Color(hex: 0x40c8ff) : Color(hex: 0x0d5bb5)
    }

    /// 팝오버 알약. 등급 색과 같은 규칙으로 밝기마다 뒤집힌다.
    ///
    /// 어두운 쪽은 밝은 파랑에 검은 숫자다. 검은 글자 대비 10.92 로 초록
    /// 알약(9.90)과 같은 수준이다. 밝은 쪽은 짙은 파랑에 흰 숫자이고
    /// 대비는 9.0 이다. `UsageBand.gaugePill(dark:)` 과 같이 움직인다.
    static func pill(dark: Bool) -> Color {
        dark ? Color(hex: 0x40c8ff) : Color(hex: 0x004a94)
    }

    /// 알약 안 막대. 양쪽 다 밝은 파랑이다.
    ///
    /// 어두운 쪽은 알약과 같은 색이고 트랙에 덮인 검정 25% 가 둘을 가른다.
    /// 밝은 쪽은 알약이 짙어졌으므로 이 색이 그 위에 얹힌다.
    static let fill = Color(hex: 0x40c8ff)
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
    /// 주간 Fable 줄인가. 여유 구간의 색만 민트로 바뀐다.
    var mint = false

    init(limit: UsageLimit?, direction: GaugeDirection, dark: Bool = true,
         mint: Bool = false) {
        self.used = limit?.percentUsed
        self.band = limit?.band
        self.direction = direction
        self.dark = dark
        self.mint = mint
    }

    init(used: Int?, band: UsageBand?, direction: GaugeDirection, dark: Bool = true,
         mint: Bool = false) {
        self.used = used
        self.band = band
        self.direction = direction
        self.dark = dark
        self.mint = mint
    }

    static var totalSteps: Int { Metrics.segSteps }

    static var width: CGFloat {
        CGFloat(Metrics.segSteps) * Metrics.segStepWidth + Metrics.segBorder * 2
    }
    static var height: CGFloat { Metrics.segRowHeight + Metrics.segBorder * 2 }

    var body: some View {
        let tint = mint && band == .ample
            ? FableTint.dot(dark: dark)
            : band?.dotColor(dark: dark) ?? Color.secondary
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
                    SegmentGauge(limit: org.limits[kind], direction: direction, dark: dark,
                                 mint: kind == FableTint.kind)
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
    /// 주간 Fable 줄인가. 여유 구간의 색만 민트로 바뀐다.
    var mint = false

    init(limit: UsageLimit?, direction: GaugeDirection, mint: Bool = false) {
        self.percent = limit.map { direction.displayPercent(used: $0.percentUsed) }
        self.band = limit?.band
        self.mint = mint
    }

    init(spend: SpendUsage, direction: GaugeDirection) {
        self.percent = direction.displayPercent(used: spend.percentUsed)
        self.band = spend.band
    }

    /// 숫자 색. 모르는 값은 바탕도 흐릿해서 기본색이 낫다.
    ///
    /// **밝은 팝오버는 등급을 안 본다.** 알약이 네 등급 모두 어두워졌으므로
    /// 흰 글자 하나로 통일한다. 줄마다 글자색이 갈리지 않는 것이 덤이다.
    /// 어두운 팝오버는 알약이 밝아서 등급마다 갈린다.
    private var ink: Color {
        guard let band else { return .primary }
        guard scheme == .dark else { return .white }
        return band == .normal ? .black : (band.prefersLightInk ? .white : .black)
    }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let fable = mint && band == .ample
        let tint = fable
            ? FableTint.pill(dark: scheme == .dark)
            : band?.gaugePill(dark: scheme == .dark) ?? Color.secondary.opacity(0.5)
        // 알약은 tint 로 그대로 그리고 막대만 따로 칠한다
        let fillTint = fable
            ? FableTint.fill
            : band?.gaugeFill(dark: scheme == .dark) ?? tint
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
                    // 검정을 덮으므로 등급색이 무엇이든 같은 만큼 내려간다.
                    // 밝은 쪽은 알약이 이미 막대보다 어두우므로 덮지 않는다
                    Capsule().fill(Color.black.opacity(
                        scheme == .dark ? Metrics.gaugeTrackDim : 0))
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
