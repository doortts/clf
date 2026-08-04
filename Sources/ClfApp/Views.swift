import SwiftUI
import ClfDesktop

extension UsageBand {
    var color: Color {
        switch self {
        case .empty:  return .red
        case .low:    return .orange
        case .normal: return .accentColor
        case .ample:  return .green
        }
    }
}

/// 킷의 글자 스타일. 크기를 한 자리에 모으는 것이 전부다.
///
/// 줄 높이는 손대지 않는다. SwiftUI 의 기본 줄 상자가 이미 킷의 짝
/// (13/16, 12/15, 11/14, 10/13) 과 같다. `Metrics` 의 글자 절을 보라.
extension View {
    /// Body 13/16.
    func bodyStyle(_ weight: Font.Weight = .regular) -> some View {
        font(.system(size: Metrics.bodySize, weight: weight))
    }
    /// Callout 12/15.
    func calloutStyle(_ weight: Font.Weight = .regular) -> some View {
        font(.system(size: Metrics.calloutSize, weight: weight))
    }
    /// Subheadline 11/14.
    func subheadStyle(_ weight: Font.Weight = .regular) -> some View {
        font(.system(size: Metrics.subheadSize, weight: weight))
    }
    /// Footnote 및 Caption 10/13.
    func captionStyle(_ weight: Font.Weight = .regular) -> some View {
        font(.system(size: Metrics.captionSize, weight: weight))
    }

    /// 재질 위에 얹는 단추.
    ///
    /// 킷은 같은 버튼을 Content Area 와 **Over Glass** 두 벌로 나눠 둔다.
    /// 팝오버는 재질 위이므로 후자다. macOS 26 이 준 유리 스타일이 그 자리고,
    /// 그 아래에서는 테두리 스타일이 가장 가깝다.
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// 계정 하나. 세 줄이 5시간, 주간, 모델별이다.
///
/// docs/design/ui-spec.html 의 팝오버. 리셋 문구는 값 옆이 아니라 아랫줄에
/// 둔다. 한 줄에 넣으면 값과 시각이 눈싸움을 한다.
struct OrgCard: View {
    let org: OrgUsage
    let direction: GaugeDirection
    var slot: InstanceSlot = .none
    var onLaunch: (() -> Void)?
    var onFocus: (() -> Void)?
    /// 방금 앞에 있던 창의 계정. 팝오버를 여는 순간 찾을 카드라 배경을 깐다.
    var focused = false

    @Environment(\.colorScheme) private var scheme

    /// 포커스 카드 색.
    ///
    /// 어두운 팝오버에서는 청록이 기본 점의 파랑, 게이지의 빨강/주황/초록과
    /// 제일 잘 갈린다. 밝은 팝오버에서는 그 청록이 배경에 묻힌다.
    /// docs/design/focus-card-theme-mockup.html
    ///
    /// 밝은 쪽은 시스템 파랑이다. **카드 안의 파란 점과 플랜 배지가 같은 색이
    /// 된다.** 배지는 악센트 22% 채움이고 카드는 15% 라 차이가 7% 뿐이어서
    /// 배지 경계가 흐려진다. 보라와 인디고가 그 겹침이 없는 값이었지만
    /// 시스템 파랑을 쓰기로 정했다. docs/design/focus-card-blue-mockup.html
    private var focusTint: Color { scheme == .dark ? .teal : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // 기본 인스턴스가 쓰는 계정은 악센트 점을 붙인다. 빨강은 이
                // 화면에서 소진이라 강조로 쓰면 위험 신호로 읽힌다.
                // docs/design/popover-hig-mockup.html
                if slot == .primary {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                }
                // 배지 둘과 단추가 같은 줄에 서면 폭 312 가 모자란다. 이름을
                // 줄이고 나머지를 살린다. 접히면 카드 높이가 카드마다 달라진다
                Text(org.name).bodyStyle(.semibold)
                    .lineLimit(1).truncationMode(.tail)
                if let plan = org.plan { badge(plan, tint: .accentColor) }
                // 정상은 아무 말도 하지 않는다. 배지가 늘 켜져 있으면 안 읽힌다
                if let band = org.binding?.band, band.isNoteworthy {
                    badge(band.label, tint: band.fillColor)
                }
                // 창이 떠 있다는 상태. 동작은 오른쪽 단추가 맡는다
                if let state = slot.badgeLabel { runningBadge(state) }
                Spacer(minLength: 8)
                slotControl
            }

            if !org.hasUsage, let error = org.error {
                Text(error).subheadStyle().foregroundStyle(.secondary)
            } else if let spend = org.spend, org.limits.isEmpty {
                // Enterprise 는 시간 창이 없다. 없는 창 셋을 억지로 그리지 않는다
                budgetRow(spend)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(LimitKind.allCases, id: \.self) { kind in
                        row(kind, org.limits[kind])
                    }
                }
                // 값은 옛것이고 사유는 새것이다. 값만 보여주면 사용자가
                // 옛 값을 지금 값으로 믿는다
                if org.isStale, let error = org.error {
                    Text("갱신 못 함. \(error)")
                        .captionStyle().foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 12)
        // 방금까지 보던 창의 계정이 한눈에 잡히게 카드를 깐다. 이 색은
        // 카드 전용이다. 점, 배지, 메뉴바 밑줄의 파랑(악센트)과 게이지의
        // 빨강/주황/초록에서 색을 갈라 카드만 "방금 그 창" 을 말한다.
        .background {
            if focused {
                RoundedRectangle(cornerRadius: 8)
                    .fill(focusTint.opacity(0.15))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(focusTint.opacity(0.60), lineWidth: 1)
                    }
                    .padding(.horizontal, -8)
            }
        }
        // 낡은 값임을 눈으로도 알린다
        .opacity(org.isStale ? 0.62 : 1)
    }

    /// 상태는 배지로 갔다. 단추에는 동사만 남아 설명 없이 읽힌다.
    /// 시스템 스타일이라 hover 와 눌림, 포커스 링이 공짜로 생긴다.
    @ViewBuilder private var slotControl: some View {
        switch slot {
        // 크기는 기본(regular)이다. 재 보면 small 이 17, regular 가 20 이고
        // 킷이 적은 24 는 어느 크기에도 없다. 우리가 그리는 상자도 20 에
        // 맞춰 둔다. docs/design/popover-hig27-applied-mockup.html
        case .none:
            Button(slot.actionLabel ?? "") { onLaunch?() }
                .glassButton(prominent: true)
                .calloutStyle(.medium)
                .accessibilityLabel("\(org.name) 계정으로 새 창 띄우기")
        case .running:
            Button(slot.actionLabel ?? "") { onFocus?() }
                .glassButton()
                .calloutStyle(.medium)
                .accessibilityLabel("\(org.name) 창을 앞으로")
        case .opening:
            statusBox(slot.label, tint: .secondary)
        case .primary, .unavailable:
            statusBox(slot.label, tint: .secondary)
        }
    }

    /// 단추가 앉는 자리에 상태만 앉는 경우다.
    ///
    /// **높이는 단추와 같아야 한다.** 카드마다 이 자리가 단추와 상자로 갈리는데
    /// 높이가 다르면 줄이 들쭉날쭉해진다. 대신 **누를 수 있게 보여서는 안 된다.**
    /// 테두리를 두르고 12pt 글자를 쓰면 옆 카드의 단추와 똑같이 생겨서 눌러
    /// 보게 된다. 테두리를 빼고 글자를 한 단 내려 배지처럼 읽히게 둔다.
    private func statusBox(_ text: String, tint: Color) -> some View {
        Text(text)
            .captionStyle(.medium)
            .foregroundStyle(tint)
            .padding(.horizontal, Metrics.controlPadding)
            .frame(height: Metrics.controlHeight)
            .background(tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
    }

    /// 창이 떠 있다는 상태 배지. 노란 점이 창을 뜻한다.
    private func runningBadge(_ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(Color.yellow).frame(width: 5, height: 5)
            Text(text).captionStyle(.semibold)
        }
        .foregroundStyle(Color.yellow)
        .padding(.horizontal, 6)
        .frame(height: Metrics.badgeHeight)
        .background(Color.yellow.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: Metrics.badgeRadius))
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .captionStyle(.semibold)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: Metrics.badgeHeight)
            .background(tint.opacity(0.22),
                        in: RoundedRectangle(cornerRadius: Metrics.badgeRadius))
    }

    /// 월 예산 한 줄. 리셋 자리에는 쓴 금액과 한도를 적는다.
    private func budgetRow(_ spend: SpendUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // 이 줄의 간격 7 과 아래 들여쓰기 65 는 게이지 폭을 정한다.
            // 게이지는 이번 범위가 아니므로 4의 배수 정리에서 뺀다
            HStack(spacing: 7) {
                Text("월 예산")
                    .subheadStyle().foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                UsageGauge(spend: spend, direction: direction)
            }
            Text("\(spend.usedText) / \(spend.limitText) 사용")
                .captionStyle().foregroundStyle(.tertiary)
                .padding(.leading, 65)
        }
    }

    private func row(_ kind: LimitKind, _ limit: UsageLimit?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // 간격 7 과 들여쓰기 65 는 게이지 폭을 정한다. 건드리지 않는다
            HStack(spacing: 7) {
                Text(kind.label)
                    .subheadStyle().foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                UsageGauge(limit: limit, direction: direction,
                           mint: kind == FableTint.kind)
            }
            Text(BarText.reset(limit?.resetsAt, window: kind.window, direction: direction))
                .captionStyle().foregroundStyle(.tertiary)
                .padding(.leading, 65)
        }
    }
}

/// 어느 계정을 어떤 차례로 볼지. 팝오버 안에서 접었다 편다.
struct SettingsPane: View {
    @ObservedObject var model: UsageModel

    /// 되돌릴 수 없는 일이다. 무엇이 사라지는지 보여주고 확인을 받는다.
    @ViewBuilder private var purgeSection: some View {
        if let plan = model.purgePlan {
            VStack(alignment: .leading, spacing: 4) {
                Text("지울 것").captionStyle(.semibold)
                Text(plan.summary)
                    .captionStyle().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(plan.consequence)
                    .captionStyle().foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { model.cancelPurge() } label: {
                        boxLabel("취소", color: .secondary, filled: false)
                    }
                    .buttonStyle(.plain)
                    Button { model.confirmPurge() } label: {
                        boxLabel("\(PurgePlan.size(plan.freedBytes)) 지운다",
                                 color: .red, filled: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("확인하고 지운다")
                }
            }
            .padding(8)
            // 상자급 반지름은 8 로 통일한다. 팝오버 20 에서 여백을 뺀 동심값
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Metrics.boxRadius))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button { model.previewPurge() } label: {
                    boxLabel("멀티 인스턴스 정보 삭제", color: .red, filled: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("새 창용 데이터 디렉토리 삭제")

                Text("~/.claude-alt-* 를 지운다. 떠 있는 창의 것은 남는다")
                    .captionStyle().foregroundStyle(.tertiary)
            }
        }
        // 결과는 누른 자리 바로 아래 둔다. 위에 있으면 눈이 안 간다
        if let notice = model.instanceNotice {
            Text(notice)
                .captionStyle().foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    /// 세그먼트 왼쪽에 붙는 좁은 라벨 열.
    private func settingRow(_ label: String,
                            @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .subheadStyle().foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            content()
        }
    }

    /// 킷의 푸시 버튼 치수다. 높이 24, 좌우 16, 모서리 6, 글자 12.
    private func boxLabel(_ text: String, color: Color, filled: Bool) -> some View {
        Text(text)
            .calloutStyle(.medium)
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, Metrics.controlPadding)
            .frame(height: Metrics.controlHeight)
            .background {
                RoundedRectangle(cornerRadius: Metrics.controlRadius)
                    .fill(filled ? color : color.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.controlRadius)
                            .strokeBorder(filled ? .clear : color.opacity(0.45), lineWidth: 1)
                    }
            }
    }

    /// 계정 한 줄. 켜고 끄고 차례를 바꾼다.
    private func accountRow(_ org: OrgUsage) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { !model.prefs.isHidden(org.uuid) },
                set: { model.setHidden(org.uuid, !$0) }
            )) {
                Text(org.name).subheadStyle()
            }
            .toggleStyle(.checkbox)
            Spacer()
            // 화살표 그림에는 읽을 글자가 없다. 이름을 붙여줘야 한다
            Button { model.move(org.uuid, by: -1) } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("\(org.name) 위로")
            Button { model.move(org.uuid, by: 1) } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("\(org.name) 아래로")
        }
        .buttonStyle(.borderless)
        .captionStyle()
    }

    /// 범위를 고르는 칸과 계정 목록은 한 가지를 정하는 짝이다. 떼어 놓으면
    /// 목록이 무엇을 정하는지 안 보인다. docs/design/settings-group-mockup.html
    private var barAccountsGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("메뉴바에 표시할 계정")
                .subheadStyle(.semibold)

            VStack(alignment: .leading, spacing: 0) {
                Picker("막대", selection: Binding(
                    get: { model.prefs.barContent },
                    set: { model.setBarContent($0) }
                )) {
                    ForEach(BarContent.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // 두 항목의 기준이 달라서 이름만으로는 안 갈린다. 고른 쪽이
                // 무엇을 보고 정하는지 한 줄로 붙인다
                Text(model.prefs.barContent.detail)
                    .captionStyle().foregroundStyle(.secondary)
                    .padding(.top, 4)

                Divider().padding(.vertical, 8)

                ForEach(model.known) { org in accountRow(org) }

                // 목록이 막대를 정하는지 아닌지가 고른 칸에 따라 다르다
                Text(model.prefs.barContent.listNote)
                    .captionStyle().foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // 검정 덮기 대신 라벨색 퍼센트. 킷의 빈 트랙과 카드 바탕이 이렇게
            // 되어 있어 라이트에서도 다크에서도 같은 만큼 가라앉는다
            .background(RoundedRectangle(cornerRadius: Metrics.boxRadius).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: Metrics.boxRadius).stroke(Color.primary.opacity(0.10)))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            barAccountsGroup

            // 세그먼트만 쌓아 두면 무엇을 고르는지 기억에 의존한다.
            // 왼쪽에 좁은 라벨 열을 붙인다. popover-hig-mockup.html
            settingRow("메뉴바 구성") {
                Picker("메뉴바 구성", selection: Binding(
                    get: { model.prefs.barDetail },
                    set: { model.setBarDetail($0) }
                )) {
                    ForEach(BarDetail.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            settingRow("표시 기준") {
                Picker("표시 기준", selection: Binding(
                    get: { model.prefs.gaugeDirection },
                    set: { model.setGaugeDirection($0) }
                )) {
                    ForEach(GaugeDirection.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // 숫자 옆 라벨 자리. 도트만/코드만 모드에는 그 줄이 없어서 고를
            // 것도 없다. 줄을 없애면 모드를 바꿀 때마다 설정 높이가 튀므로
            // 흐리게 두고 못 누르게 한다.
            // docs/design/bar-reset-remaining-mockup.html
            settingRow("리셋 표기") {
                Picker("리셋 표기", selection: Binding(
                    get: { model.prefs.resetLabel },
                    set: { model.setResetLabel($0) }
                )) {
                    ForEach(ResetLabel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.prefs.barDetail.showsNumbers)
            }
            .opacity(model.prefs.barDetail.showsNumbers ? 1 : 0.4)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(
                    get: { model.loginItem.isChecked },
                    set: { model.setLoginItem($0) }
                )) {
                    Text(model.loginItem.label).subheadStyle()
                }
                .toggleStyle(.checkbox)
                .disabled(!model.loginItem.isToggleable)

                if let hint = model.loginItem.hint {
                    HStack(spacing: 4) {
                        Text(hint).captionStyle().foregroundStyle(.secondary)
                        if model.loginItem == .needsApproval {
                            // 경로를 말로 설명하는 것보다 열어주는 편이 낫다
                            Button("열기...") { model.openLoginItemSettings() }
                                .buttonStyle(.borderless).captionStyle()
                                .accessibilityLabel("로그인 항목 설정 열기")
                        }
                    }
                    // 체크박스 글자와 맞추는 들여쓰기다. 4의 배수로 맞춘다
                    .padding(.leading, 20)
                }
            }

            Divider()

            // 알림은 한 칸이다. 예고와 소진을 따로 끄고 싶다는 말이 나오면
            // 그때 가른다. docs/design/notify-mockup.html
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(
                    get: { model.prefs.notify },
                    set: { model.setNotify($0) }
                )) {
                    Text("한도가 바닥나면 알림").subheadStyle()
                }
                .toggleStyle(.checkbox)

                if model.prefs.notify, model.notifyPermission == .denied {
                    // 체크가 켜져도 시스템이 막으면 안 온다. 그 사실과 길을 같이
                    HStack(spacing: 4) {
                        Text("시스템 설정에서 알림을 허용해야 합니다")
                            .captionStyle().foregroundStyle(.secondary)
                        Button("열기...") { model.openNotificationSettings() }
                            .buttonStyle(.borderless).captionStyle()
                            .accessibilityLabel("알림 설정 열기")
                    }
                    .padding(.leading, 20)
                } else {
                    Text("빨강(5% 미만)에 들어설 때와 다 썼을 때 보냅니다")
                        .captionStyle().foregroundStyle(.tertiary)
                        .padding(.leading, 20)
                }
            }

            Divider()

            // 새 창을 띄우면 계정마다 300MB 쯤 쌓인다. 지울 자리가 필요하다
            purgeSection
        }
    }
}

struct PopoverView: View {
    @ObservedObject var model: UsageModel
    @State private var showingSettings = false
    @StateObject private var sharedSessions = SharedSessionModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("clf").bodyStyle(.semibold)
                // 숫자가 어느 기준인지 연 순간 알린다. 항상 떠 있는 표시라
                // 눈길을 끌면 안 된다. docs/design/header-direction-mockup.html
                Text("\(model.prefs.gaugeDirection.label) 기준")
                    .calloutStyle().foregroundStyle(.secondary)
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.refreshing)
                // 여기만 시스템 툴팁이다. 우리 hoverTip 은 단추 위로 띄우는데
                // 이 둘은 팝오버 맨 윗줄이라 위가 없어서 잘린다
                .help("지금 새로고침")
                .accessibilityLabel("지금 새로고침")
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { showingSettings.toggle() }
                } label: {
                    Image(systemName: showingSettings ? "gearshape.fill" : "gearshape")
                }
                .help(showingSettings ? "설정 닫기" : "설정 열기")
                .accessibilityLabel(showingSettings ? "설정 닫기" : "설정 열기")
            }
            .buttonStyle(.borderless)
            .calloutStyle()
            .padding(.bottom, 8)

            if let failure = model.failure {
                Text(failure)
                    .captionStyle().foregroundStyle(.red)
                    .padding(.bottom, 8)
            }
            if let wait = model.waitText {
                Text("요청이 몰려 쉬는 중. \(wait) 다시 읽는다")
                    .captionStyle().foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }

            if model.orgs.isEmpty {
                Text(model.readAt == nil ? "읽는 중" : "볼 계정을 하나도 안 켰다")
                    .subheadStyle().foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                // 카드 사이에 선을 긋지 않는다. 카드마다 위아래 여백이
                // 있어서 선까지 그으면 칸막이가 두 겹이 된다
                ForEach(Array(model.orgs.enumerated()), id: \.element.id) { _, org in
                    OrgCard(org: org, direction: model.prefs.gaugeDirection, slot: model.slot(org),
                            onLaunch: { model.launch(org) },
                            onFocus: { model.focus(org) },
                            focused: org.uuid == model.focusedUUID)
                }
            }

            // 겹칠 때만 나타난다. 대화마다 계정이 하나뿐인 평소에는 없다
            SharedSessionSection(model: sharedSessions, names: model.accountNames)

            if showingSettings {
                SettingsPane(model: model)
                    .padding(.top, 12)
                Divider().padding(.vertical, 8)
            }

            HStack(spacing: 12) {
                Text(model.readAt.map { stamp($0) } ?? "-")
                    .captionStyle().foregroundStyle(.tertiary)
                Spacer()
                // 여기만 테두리를 두른다. 종료까지 단추로 만들면 창을 끄는
                // 쪽이 같은 무게로 올라선다
                Button {
                    // 팝오버를 먼저 닫는다. 열린 채 두면 키 창 자리를 쥐고
                    // 있어서 넘기기 창이 떠도 포커스를 못 받는다
                    NSApp.keyWindow?.close()
                    HandoffWindow.open()
                } label: {
                    // 창을 여는 단추에는 말줄임표를 붙인다
                    Label("세션 작업 이전...", systemImage: "arrow.left.arrow.right")
                        .calloutStyle(.medium)
                }
                .glassButton()
                .hoverTip(Copy.handoffHelp)
                .accessibilityLabel("세션 작업을 다른 계정으로 이전한다")
                .accessibilityHint(Copy.handoffHelp)
                Button { NSApplication.shared.terminate(nil) } label: {
                    // 빨강은 데이터가 사라지는 삭제의 색이다. 앱을 닫는 것은
                    // 그 역할이 아니라서 보통 색으로 둔다
                    Label("종료", systemImage: "power")
                        .calloutStyle(.medium)
                }
                .accessibilityLabel("clf 종료")
            }
            .buttonStyle(.borderless)
            // 카드 영역과 하단 조작 줄은 다른 얘기다. 선 대신 여백으로
            // 구획을 만든다. 설정을 편 상태에는 위에 선과 간격이 이미 있다.
            // docs/design/footer-gap-mockup.html A안
            .padding(.top, showingSettings ? 0 : 16)
        }
        .padding(Metrics.popoverPadding)
        .frame(width: Metrics.popoverWidth)
        // 두 테마 모두 재질 하나로 간다. 테마마다 다른 것을 깔던 것이 원래
        // 문제였다. 라이트만 불투명 흰 판이라 다크와 다른 앱처럼 보였고,
        // 흰 판을 흰색 70% 세 겹으로 바꾸는 것도 결국 같은 분기다.
        //
        // 킷은 재질을 Ultrathick~Ultrathin 다섯 토큰으로 두고 팝오버에는 Thick
        // 을 쓴다. 그 자리가 SwiftUI 의 .thickMaterial 이다. 기본 반투명보다
        // 두꺼워서 벽지가 배어 나오지 않는다.
        // docs/design/popover-hig27-applied-mockup.html
        .background(.thickMaterial)
        .task {
            // 지난 결과는 한 번 읽으면 끝이다. 다시 열면 깨끗한 화면부터
            model.clearNotice()
            // 계정은 로컬 파일이라 공짜다. 열자마자 지금 값을 본다
            await model.refreshActiveNow()
            // 겹친 세션도 로컬 파일이다. 열 때 한 번만 훑는다
            sharedSessions.refresh()
            await model.refresh()
        }
    }

    private func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date) + " 갱신"
    }
}

/// 화면에 쓰는 긴 안내 문구. 툴팁과 접근성 힌트가 같은 말을 써야 한다.
enum Copy {
    static let handoffHelp = "다른 계정으로 세션을 이동시켜서 작업을 재개할 수 있도록 도와줍니다"
}

/// 올려두면 곧바로 뜨는 툴팁.
///
/// `.help()` 를 안 쓴다. macOS 가 정한 지연(1초 남짓) 뒤에야 뜨고 그 값은
/// 우리가 못 바꾼다. 툴팁은 눌러도 되는지 망설이는 그 순간에 떠야 쓸모가
/// 있어서 직접 그린다. docs/design/handoff-button-mockup.html
struct HoverTip: ViewModifier {
    let text: String
    var width: CGFloat = 214
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .onHover { showing = $0 }
            // 팝오버 바닥에 있는 단추라 위로 띄운다. 오른쪽 끝을 맞춘다.
            //
            // 높이 0 짜리 자리에 아래쪽 정렬로 넣으면 그 위로 넘쳐 나간다.
            // 툴팁 높이를 재지 않아도 되고 줄 수가 늘어도 따라 올라간다
            .overlay(alignment: .topTrailing) {
                if showing {
                    bubble
                        .fixedSize()
                        .frame(height: 0, alignment: .bottom)
                        .offset(y: -6)
                }
            }
    }

    private var bubble: some View {
        Text(text)
            .subheadStyle()
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.14)))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            // 툴팁이 클릭을 가로채면 단추가 안 눌린다
            .allowsHitTesting(false)
    }
}

extension View {
    func hoverTip(_ text: String) -> some View { modifier(HoverTip(text: text)) }
}
