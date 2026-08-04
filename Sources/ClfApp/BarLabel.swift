import AppKit
import SwiftUI
import ClfDesktop

/// 막대 글자의 실제 폭. 열 폭을 계정마다 그 계정의 가장 긴 글자에 맞춘다.
///
/// 폭을 못박지 않으면 두 줄의 퍼센트가 세로로 어긋나고, 가장 긴 글자
/// (`23h`, `100%`) 기준으로 못박으면 짧은 줄에 빈자리가 7pt 씩 남는다. 계정마다
/// 재서 정하면 정렬은 지키면서 빈자리가 사라진다.
/// docs/design/bar-compact-mockup.html C안
enum BarGlyph {
    /// 막대 글자는 10pt medium 이고 숫자만 고정폭이다. `BarOrgView` 가 쓰는
    /// 글꼴과 같아야 재는 값이 맞는다.
    static func width(_ text: String, mono: Bool) -> CGFloat {
        let size = Metrics.captionSize
        let font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
            : NSFont.systemFont(ofSize: size, weight: .medium)
        // 올림한다. 재 온 값보다 SwiftUI 가 반 픽셀 더 쓰면 글자가 눌린다
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// 막대에 그리는 한 계정. 코드, 숫자 두 줄, 도트 블록 세 줄.
///
/// docs/design/ui-spec.html 의 "기본" 모드. 숫자는 자주 보는 두 창을 정확히,
/// 블록은 셋을 한눈에 담는다. 숫자만 두면 셋째 창이 안 보이고, 블록만 두면
/// 정확한 값을 못 읽는다.
struct BarOrgView: View {
    let code: String
    let org: OrgUsage
    let detail: BarDetail
    let direction: GaugeDirection
    /// 숫자 옆 라벨을 창 종류로 적을지 남은 시간으로 적을지.
    var resetLabel: ResetLabel = .remaining
    /// 남은 시간을 재는 기준 시각. 구울 때 박히므로 밖에서 준다.
    var now = Date()
    /// 이 계정의 창이 지금 앞에 있는가. 코드 아래에 파란 밑줄이 붙는다.
    var focused = false
    var dark = true

    /// 숫자 칸 한 줄. 라벨은 없을 수 있다.
    private struct Row {
        let tag: String?
        let value: String
        let band: UsageBand?
    }

    /// 그릴 줄들. Enterprise 는 창이 없어 예산 한 줄이 전부다.
    private var rows: [Row] {
        if let spend = org.spend, org.limits.isEmpty {
            // 리셋도 없으므로 남은 시간을 골라도 라벨은 `예산` 이다
            return [Row(tag: resetLabel.showsTag ? "예산" : nil,
                        value: "\(direction.displayPercent(used: spend.percentUsed))%",
                        band: spend.band)]
        }
        // 세 창인데 숫자는 두 줄이 한계다. 셋째 줄은 자리가 없어 게이지만 남는다
        return [row(.session, "5h"), row(.weeklyAll, "1w")]
    }

    private func row(_ kind: LimitKind, _ period: String) -> Row {
        let limit = org.limits[kind]
        return Row(tag: tag(kind, period),
                   value: limit.map { "\(direction.displayPercent(used: $0.percentUsed))%" }
                            ?? BarText.unknown,
                   band: limit?.band)
    }

    /// 라벨 한 칸. 창 종류이거나 남은 시간이거나 아예 없다.
    private func tag(_ kind: LimitKind, _ period: String) -> String? {
        switch resetLabel {
        case .none:   return nil
        case .period: return period
        case .remaining:
            // 사용률 0 인 창은 서버가 리셋 시각을 안 준다. 아직 안 써서 타이머가
            // 걸리지도 않았다. 없는 시간을 적을 자리가 아니므로 열을 비운다.
            // 창 길이(5h)를 적어 봤더니 "5시간 뒤 리셋" 으로 읽혔다
            guard let resetsAt = org.limits[kind]?.resetsAt else { return nil }
            return BarText.shortUntil(resetsAt, from: now)
        }
    }

    /// 라벨 열 폭. 이 계정의 가장 긴 라벨에 맞춘다. 라벨이 하나도 없으면 nil 이고
    /// 그때는 열 자체가 사라진다.
    private var tagColumn: CGFloat? {
        guard resetLabel.showsTag else { return nil }
        let widest = rows.compactMap(\.tag).map { BarGlyph.width($0, mono: false) }.max() ?? 0
        return widest > 0 ? widest : nil
    }

    /// 값 열 폭. 오른쪽 정렬이라 자릿수가 갈려도 오른쪽 끝이 맞는다.
    private var valueColumn: CGFloat {
        rows.map { BarGlyph.width($0.value, mono: true) }.max() ?? 0
    }

    var body: some View {
        HStack(spacing: Metrics.barGap) {
            Text(code).font(.system(size: 12, weight: .semibold))
                // 흰색으로 박는다. 메뉴바는 벽지 위에 반투명으로 얹히므로
                // 시스템 외양이 라이트여도 실제 바탕은 어두울 수 있다.
                // 그때 기본색(검정)으로 구우면 코드가 안 보인다
                .foregroundStyle(.white)
                .overlay(alignment: .bottom) {
                    if focused {
                        // 코드 폭만. 등급색과 안 겹치는 파랑이라 상태가
                        // 아니라 위치를 말한다는 것이 색으로 갈린다.
                        // 시안은 1pt 를 권했지만 실기기에서 너무 얇았다.
                        // docs/design/focus-underline-mockup.html
                        Rectangle()
                            .fill(dark ? Color(hex: 0x0a84ff) : Color(hex: 0x007aff))
                            .frame(height: 1.5)
                            .offset(y: 1.5)
                    }
                }

            if detail.showsNumbers {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        line(row)
                    }
                }
            }
            if detail.showsDots {
                SegmentBlock(org: org, direction: direction, dark: dark)
            }
        }
        .fixedSize()
    }

    private func line(_ row: Row) -> some View {
        // 글자 10pt 는 macOS 최소치다. 9pt 는 그 아래였다. 아래 frame 이
        // 줄 상자를 11pt 로 누른다. 10pt 의 자연 줄 상자가 13pt 라 2pt 를 누르는
        // 셈이고, 그게 없으면 두 줄이 26pt 로 메뉴바 24pt 를 넘는다. 실측으로
        // 잘리지는 않지만 위아래 여유가 1px 뿐이다.
        //
        // 색을 값으로 박는 것은 이 화면만의 예외다. 구운 이미지라 재질도
        // vibrancy 도 없어서 시스템 라벨색이 적응할 바탕 자체가 없다.
        // docs/design/popover-hig27-applied-mockup.html
        HStack(spacing: Metrics.barTagGap) {
            // 라벨을 끄면(없음 모드) 칸이 아니라 열이 사라진다. 켜 두면 라벨이
            // 없는 줄도 폭을 지킨다. 그러지 않으면 타이머가 안 걸린 창의 숫자만
            // 앞으로 당겨져 두 줄의 퍼센트가 어긋난다
            if let tagColumn {
                Text(row.tag ?? "")
                    .font(.system(size: Metrics.captionSize, weight: .medium))
                    // 코드와 같은 이유로 색을 박는다. .tertiary 는 어두운 바탕에서
                    // 거의 사라졌다. 숫자보다는 뒤로 물러나야 하니 회색으로 둔다
                    .foregroundStyle(Color(white: 0.78))
                    .frame(minWidth: tagColumn, alignment: .trailing)
            }
            Text(row.value)
                .font(.system(size: Metrics.captionSize, weight: .medium).monospacedDigit())
                .foregroundStyle(row.band?.fillColor ?? .secondary)
                // 100% 는 네 글자다. 자리가 좁으면 % 가 다음 줄로 떨어진다
                .lineLimit(1)
                // 오른쪽 정렬이라 두 자리와 세 자리의 오른쪽 끝이 맞는다.
                // 라벨 열이 따로 고정돼 있어서 라벨은 제자리다
                .frame(minWidth: valueColumn, alignment: .trailing)
        }
        .frame(height: 11)
    }
}

struct BarLabelView: View {
    let orgs: [OrgUsage]
    let detail: BarDetail
    let direction: GaugeDirection
    var resetLabel: ResetLabel = .remaining
    var now = Date()
    /// 앞 창의 계정. 막대에 없는 계정이면 아무 데도 안 그려진다.
    var focusedUUID: String? = nil
    var dark = true

    var body: some View {
        let codes = BarText.codes(for: orgs.map(\.name))
        HStack(spacing: Metrics.barOrgGap) {
            if orgs.isEmpty {
                Text(BarText.placeholder).font(.system(size: 12, weight: .semibold))
            } else {
                ForEach(orgs) { org in
                    BarOrgView(code: codes[org.name] ?? BarText.unknown, org: org,
                               detail: detail, direction: direction,
                               resetLabel: resetLabel, now: now,
                               focused: org.uuid == focusedUUID, dark: dark)
                }
            }
        }
        .padding(.horizontal, 1)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// 막대 그림을 이미지로 굽는다.
///
/// `MenuBarExtra` 는 라벨을 템플릿으로 그린다. 그대로 두면 색이 전부 날아가
/// 잔여 등급을 구별할 수 없다. `ImageRenderer` 로 구운 뒤 `isTemplate` 을 꺼야
/// 시안대로 색이 남는다.
///
/// **대신 색이 구울 때 박힌다.** 적응형 색을 쓸 수 없으므로 지금 메뉴바가
/// 밝은지 어두운지를 보고 그려야 하고, 시스템 외양이 바뀌면 다시 구워야 한다.
/// 그러지 않으면 다크 메뉴바에 검은 글씨가 얹혀 안 보인다.
@MainActor
enum BarImage {
    /// 메뉴바는 시스템 외양을 따른다.
    static var menuBarIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func render(orgs: [OrgUsage], detail: BarDetail, direction: GaugeDirection,
                       resetLabel: ResetLabel = .remaining, now: Date = Date(),
                       focusedUUID: String? = nil, scale: CGFloat = 2) -> NSImage? {
        let dark = menuBarIsDark
        let renderer = ImageRenderer(
            content: BarLabelView(orgs: orgs, detail: detail, direction: direction,
                                  resetLabel: resetLabel, now: now,
                                  focusedUUID: focusedUUID, dark: dark))
        renderer.scale = scale
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        return image
    }
}
