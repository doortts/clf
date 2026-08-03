import SwiftUI
import ClfDesktop

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
    /// 이 계정의 창이 지금 앞에 있는가. 코드 아래에 파란 밑줄이 붙는다.
    var focused = false
    var dark = true

    var body: some View {
        HStack(spacing: 3) {
            Text(code).font(.system(size: 12, weight: .semibold))
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
                // 세 창인데 숫자는 두 줄이 한계다. 어느 창인지 라벨로 못박는다.
                // 셋째 줄은 자리가 없어 게이지만 남는다
                VStack(alignment: .leading, spacing: -1) {
                    if let spend = org.spend, org.limits.isEmpty {
                        // Enterprise 는 창이 없다. 예산 한 줄이 전부다
                        value("예산", "\(direction.displayPercent(used: spend.percentUsed))%",
                              spend.band)
                    } else {
                        number(.session, "5h")
                        number(.weeklyAll, "1w")
                    }
                }
            }
            if detail.showsDots {
                SegmentBlock(org: org, direction: direction, dark: dark)
            }
        }
        .fixedSize()
    }

    /// 걸린 창의 숫자만 색이 바뀐다. 라벨은 그대로 둔다.
    private func number(_ kind: LimitKind, _ tag: String) -> some View {
        let limit = org.limits[kind]
        return value(tag, limit.map { "\(direction.displayPercent(used: $0.percentUsed))%" }
                        ?? BarText.unknown,
                     limit?.band)
    }

    private func value(_ tag: String, _ text: String, _ band: UsageBand?) -> some View {
        // 라벨과 숫자 사이는 2.5pt = 5px 다. 숫자를 오른쪽 정렬 상자에 넣으면
        // 값이 짧을 때 상자 안쪽 여백까지 더해져 사이가 두 배로 벌어졌다.
        // 상자를 걷어내고 간격만 남긴다. 오른쪽 끝이 들쭉날쭉해지지만
        // 게이지 자리는 VStack 이 잡아 주므로 흔들리지 않는다
        HStack(spacing: 2.5) {
            Text(tag)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(band?.fillColor ?? .secondary)
                // 100% 는 네 글자다. 자리가 좁으면 % 가 다음 줄로 떨어진다
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct BarLabelView: View {
    let orgs: [OrgUsage]
    let detail: BarDetail
    let direction: GaugeDirection
    /// 앞 창의 계정. 막대에 없는 계정이면 아무 데도 안 그려진다.
    var focusedUUID: String? = nil
    var dark = true

    var body: some View {
        let codes = BarText.codes(for: orgs.map(\.name))
        HStack(spacing: 7) {
            if orgs.isEmpty {
                Text(BarText.placeholder).font(.system(size: 12, weight: .semibold))
            } else {
                ForEach(orgs) { org in
                    BarOrgView(code: codes[org.name] ?? BarText.unknown, org: org,
                               detail: detail, direction: direction,
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
                       focusedUUID: String? = nil, scale: CGFloat = 2) -> NSImage? {
        let dark = menuBarIsDark
        let renderer = ImageRenderer(
            content: BarLabelView(orgs: orgs, detail: detail, direction: direction,
                                  focusedUUID: focusedUUID, dark: dark))
        renderer.scale = scale
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        return image
    }
}
