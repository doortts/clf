import SwiftUI
import ClflDesktop

/// 막대에 그리는 한 조직. 코드, 숫자 두 줄, 도트 블록 세 줄.
///
/// docs/design/ui-spec.html 의 "기본" 모드. 숫자는 자주 보는 두 창을 정확히,
/// 블록은 셋을 한눈에 담는다. 숫자만 두면 셋째 창이 안 보이고, 블록만 두면
/// 정확한 값을 못 읽는다.
struct BarOrgView: View {
    let code: String
    let org: OrgUsage
    let detail: BarDetail
    var dark = true

    var body: some View {
        HStack(spacing: 3) {
            Text(code).font(.system(size: 12, weight: .semibold))

            if detail.showsNumbers {
                // 세 창인데 숫자는 두 줄이 한계다. 어느 창인지 라벨로 못박는다.
                // 셋째 줄은 자리가 없어 게이지만 남는다
                VStack(alignment: .leading, spacing: -1) {
                    number(.session, "5h")
                    number(.weeklyAll, "1w")
                }
            }
            if detail.showsDots {
                SegmentBlock(limits: org.limits, dark: dark)
            }
        }
        .fixedSize()
    }

    /// 걸린 창의 숫자만 색이 바뀐다. 라벨은 그대로 둔다.
    private func number(_ kind: LimitKind, _ tag: String) -> some View {
        let limit = org.limits[kind]
        return HStack(spacing: 3) {
            Text(tag)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(limit.map { "\($0.percentRemaining)%" } ?? BarText.unknown)
                .font(.system(size: 8, weight: .medium).monospacedDigit())
                .foregroundStyle(limit?.band.fillColor ?? .secondary)
                .frame(width: 22, alignment: .trailing)
        }
    }
}

struct BarLabelView: View {
    let orgs: [OrgUsage]
    let detail: BarDetail
    var dark = true

    var body: some View {
        let codes = BarText.codes(for: orgs.map(\.name))
        HStack(spacing: 7) {
            if orgs.isEmpty {
                Text(BarText.placeholder).font(.system(size: 12, weight: .semibold))
            } else {
                ForEach(orgs) { org in
                    BarOrgView(code: codes[org.name] ?? BarText.unknown, org: org,
                               detail: detail, dark: dark)
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

    static func render(orgs: [OrgUsage], detail: BarDetail, scale: CGFloat = 2) -> NSImage? {
        let dark = menuBarIsDark
        let renderer = ImageRenderer(
            content: BarLabelView(orgs: orgs, detail: detail, dark: dark))
        renderer.scale = scale
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        return image
    }
}
