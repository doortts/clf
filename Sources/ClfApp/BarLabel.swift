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
    /// 숫자 옆 라벨을 창 종류로 적을지 남은 시간으로 적을지.
    var resetLabel: ResetLabel = .remaining
    /// 남은 시간을 재는 기준 시각. 구울 때 박히므로 밖에서 준다.
    var now = Date()
    /// 이 계정의 창이 지금 앞에 있는가. 코드 아래에 파란 밑줄이 붙는다.
    var focused = false
    var dark = true

    var body: some View {
        HStack(spacing: 3) {
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
                // 세 창인데 숫자는 두 줄이 한계다. 어느 창인지 라벨로 못박는다.
                // 셋째 줄은 자리가 없어 게이지만 남는다
                // 줄 상자가 11pt 고정이라 겹칠 필요가 없다. 두 줄 = 22pt
                VStack(alignment: .leading, spacing: 0) {
                    if let spend = org.spend, org.limits.isEmpty {
                        // Enterprise 는 창이 없다. 예산 한 줄이 전부다.
                        // 리셋도 없으므로 남은 시간을 골라도 라벨은 `예산` 이다
                        value(resetLabel.showsTag ? "예산" : nil,
                              "\(direction.displayPercent(used: spend.percentUsed))%",
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
    private func number(_ kind: LimitKind, _ period: String) -> some View {
        let limit = org.limits[kind]
        return value(tag(kind, period),
                     limit.map { "\(direction.displayPercent(used: $0.percentUsed))%" }
                        ?? BarText.unknown,
                     limit?.band)
    }

    /// 라벨 한 칸. 창 종류이거나 남은 시간이거나 아예 없다.
    private func tag(_ kind: LimitKind, _ period: String) -> String? {
        switch resetLabel {
        case .none:      return nil
        case .period:    return period
        case .remaining: return BarText.shortUntil(org.limits[kind]?.resetsAt, from: now)
        }
    }

    private func value(_ tag: String?, _ text: String, _ band: UsageBand?) -> some View {
        // 라벨과 숫자 사이는 2.5pt = 5px 다. 숫자를 오른쪽 정렬 상자에 넣으면
        // 값이 짧을 때 상자 안쪽 여백까지 더해져 사이가 두 배로 벌어졌다.
        // 상자를 걷어내고 간격만 남긴다. 오른쪽 끝이 들쭉날쭉해지지만
        // 게이지 자리는 VStack 이 잡아 주므로 흔들리지 않는다
        // 글자 10pt 는 macOS 최소치다. 9pt 는 그 아래였다. 줄 상자를 11pt 로
        // 고정하면 두 줄이 22pt 로 메뉴바 24pt 안에 들어간다.
        // docs/design/popover-hig27-applied-mockup.html
        HStack(spacing: 2.5) {
            // 라벨을 끄면 칸이 아니라 열이 사라진다. 빈 Text 를 두면 간격만 남아
            // 폭이 안 줄어든다
            if let tag {
                Text(tag)
                    .font(.system(size: 10, weight: .medium))
                    // 코드와 같은 이유로 색을 박는다. .tertiary 는 어두운 바탕에서
                    // 거의 사라졌다. 숫자보다는 뒤로 물러나야 하니 회색으로 둔다
                    .foregroundStyle(Color(white: 0.78))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(band?.fillColor ?? .secondary)
                // 100% 는 네 글자다. 자리가 좁으면 % 가 다음 줄로 떨어진다
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
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
        HStack(spacing: 7) {
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
