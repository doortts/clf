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

/// 손으로 그리는 단추 상자. 팝오버 안의 모든 단추가 이 치수를 쓴다.
///
/// 높이 20 은 시스템 단추 실측값이고 좌우 12, 모서리 6, 글자 12 는 킷 값이다.
/// `Metrics` 의 단추 절을 보라. `filled` 는 주된 동작, 테두리는 부차 동작이다.
@MainActor func controlBox(_ text: String, color: Color, filled: Bool) -> some View {
    Text(text)
        .calloutStyle(.medium)
        .foregroundStyle(filled ? Color.white : color)
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

    /// 포커스 카드 색. 밝은 쪽 어두운 쪽 모두 시스템 파랑이다.
    ///
    /// 어두운 쪽은 청록이었다. 테마마다 색이 갈리면 같은 카드가 두 색으로
    /// 보여서 파랑 하나로 맞춘다. 채움을 5% 로 낮췄으니 22% 채움인 플랜
    /// 배지와 겹치지 않는다. docs/design/focus-card-blue-mockup.html
    private var focusTint: Color { .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // 배지 둘과 단추가 같은 줄에 서면 폭 312 가 모자란다. 이름을
                // 줄이고 나머지를 살린다. 접히면 카드 높이가 카드마다 달라진다
                Text(org.name).bodyStyle(.semibold)
                    .lineLimit(1).truncationMode(.tail)
                if let plan = org.plan { badge(plan, tint: .accentColor) }
                // 기본 인스턴스가 쓰는 계정. 예전에는 이름 앞 파란 점이었는데
                // 점은 범례를 알아야 읽혔다. 종류 배지 옆에 글자로 적는다.
                //
                // 회색이다. 파랑은 종류 배지가 쓰고 있고, 빨강/주황/초록은
                // 등급이 쓴다. 회색이라 뒤로 물러나서 이름과 게이지가 먼저
                // 읽힌다. 점을 뺀 8pt 와 간격 8pt 가 이름으로 돌아간다.
                // docs/design/primary-badge-mockup.html 1안
                if slot == .primary { badge(slot.label, tint: .secondary) }
                // 등급 배지는 없다. 주의든 소진이든 게이지 색과 숫자가 이미
                // 말한다. 이름 줄에는 게이지가 못 말하는 것만 남긴다.
                // 종류(플랜)와 기본 창 여부와 창이 떠 있는지다
                // 창이 떠 있다는 상태. 동작은 오른쪽 단추가 맡는다
                if let state = slot.badgeLabel { runningDot(state) }
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
                    .fill(focusTint.opacity(0.05))
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
    ///
    /// 시스템 단추 스타일을 쓰지 않는다. 이 자리는 카드마다 단추와 상태 상자로
    /// 갈리는데 시스템 단추는 높이 20 에 좌우 여백과 베젤 색을 자기가 정해서
    /// 옆 카드의 상태 상자와 크기도 색도 안 맞았다. 셋 다 `controlBox` 로
    /// 그려서 높이 20, 좌우 12, 모서리 6 을 공유하고 채움과 테두리로만 갈린다.
    @ViewBuilder private var slotControl: some View {
        switch slot {
        case .none:
            Button { onLaunch?() } label: {
                controlBox(slot.actionLabel ?? "", color: .accentColor, filled: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(org.name) 계정으로 새 창 띄우기")
        // 기본 창도 꺼낸다. 이 자리가 상태 상자였을 때는 팝오버에서 원래 쓰던
        // 창으로 돌아갈 길이 없었다. 상태는 이름 옆 회색 `기본` 배지가 맡는다
        case .running, .primary:
            Button { onFocus?() } label: {
                controlBox(slot.actionLabel ?? "", color: .accentColor, filled: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(org.name) 창을 앞으로")
        case .opening, .unavailable:
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

    /// 창이 떠 있다는 상태. 노란 점 하나가 전부다.
    ///
    /// 글자까지 넣으면 배지 하나가 90pt 를 먹는다. 폭 312 에 플랜 배지와
    /// 단추가 같이 서는 줄이라 그만큼이 계정 이름에서 빠지고, 긴 이름이
    /// `NAVER_TE...` 로 잘렸다. 같은 말은 오른쪽 단추(`앞으로 꺼내기`)가
    /// 이미 하고 있으니 점만 남긴다. 읽어주는 쪽에는 문구를 넘긴다.
    private func runningDot(_ label: String) -> some View {
        Circle().fill(Color.yellow).frame(width: 6, height: 6)
            .accessibilityLabel(label)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Badge(text: text, tint: tint)
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
                        controlBox("취소", color: .secondary, filled: false)
                    }
                    .buttonStyle(.plain)
                    Button { model.confirmPurge() } label: {
                        controlBox("\(PurgePlan.size(plan.freedBytes)) 지운다",
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
                    controlBox("멀티 인스턴스 정보 삭제", color: .red, filled: false)
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
                            Button("열기") { model.openLoginItemSettings() }
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
                        Button("열기") { model.openNotificationSettings() }
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

            UpdateSection(model: model, updates: model.updates)

            Divider()

            RepoSection(updates: model.updates)

            Divider()

            // 새 창을 띄우면 계정마다 300MB 쯤 쌓인다. 지울 자리가 필요하다
            purgeSection
        }
        // 설정을 연 것이 곧 그 버전을 본 것이다. 톱니의 점이 여기서 사라진다.
        // 같은 릴리즈를 열 때마다 다시 권하지 않는다
        .onAppear { model.markUpdateSeen() }
    }
}

/// 새 버전 확인과 설치.
///
/// **확인을 켜고 끄는 체크박스는 없다.** 확인은 릴리즈 API 를 한 번 읽는 것이
/// 전부고 아무것도 바꾸지 않는다. 받고 갈아 끼우는 일은 사람이 단추를 눌러야
/// 시작한다. 끌 것이 없는 스위치를 두면 꺼 놓고 잊은 사람이 새 버전을 영영
/// 못 본다. docs/design/17-repo-split.html 5절
///
/// `updates` 를 따로 관찰한다. 상태를 `UsageModel` 의 계산 프로퍼티로 옮겨
/// 담으면 값은 맞지만 그 변화를 알리는 쪽이 없어서 화면이 안 다시 그려진다.
private struct UpdateSection: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var updates: UpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text("업데이트").subheadStyle(.semibold)
                // 팝오버 머리의 사용량 새로고침과 같은 글리프다. 같은 뜻을 두
                // 곳에서 다른 모양으로 그릴 이유가 없다.
                //
                // **돌리지 않는다.** 확인은 대개 1초 안에 끝나고 그동안 도는
                // 그림은 그 자체로 소리다. 못 누르게 하는 것으로 끝낸다
                if updates.skipped == nil {
                    Button { Task { await model.checkUpdateNow() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .captionStyle()
                    .disabled(updates.busy)
                    .hoverTip("지금 확인")
                    .accessibilityLabel("지금 업데이트 확인")
                }
            }
            statusLine
            card
            staleNotice
        }
    }

    /// 제목 아래 한 줄. 체크박스가 없으니 들여쓰기도 없다.
    @ViewBuilder private var statusLine: some View {
        if let why = updates.skipped {
            Text(why).captionStyle().foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            switch updates.state {
            case .idle:
                Text(updates.currentVersion).captionStyle().foregroundStyle(.secondary)
            case .checking:
                Text("확인 중...").captionStyle().foregroundStyle(.secondary)
            case .upToDate:
                HStack(spacing: 3) {
                    Image(systemName: "checkmark")
                    Text("\(updates.currentVersion), 최신입니다")
                }
                .captionStyle().foregroundStyle(.green)
            case .available:
                // 결과 줄은 늘 같은 자리에서 같은 것을 말한다. 새 버전은 카드
                // 제목이 된다
                Text("지금 \(updates.currentVersion)")
                    .captionStyle().foregroundStyle(.secondary)
            case .downloading(let release, _, _), .ready(let release):
                Text("\(release.tag) 으로 갈아타는 중")
                    .captionStyle().foregroundStyle(.secondary)
            case .failed(let why):
                VStack(alignment: .leading, spacing: 4) {
                    Text(why).captionStyle().foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    // **다시 시도는 남는다.** 확인 아이콘은 릴리즈를 다시 읽고
                    // 이 단추는 막힌 그 단계부터 다시 간다
                    HStack(spacing: 8) {
                        Button { Task { await updates.retry() } } label: {
                            controlBox("다시 시도", color: .secondary, filled: false)
                        }
                        .buttonStyle(.plain)
                        Button { updates.revealDownload() } label: {
                            Text("받은 파일 열기")
                        }
                        .buttonStyle(.borderless).captionStyle()
                        Button { updates.openReleaseNotes() } label: {
                            Text("직접 받기")
                        }
                        .buttonStyle(.borderless).captionStyle()
                        .accessibilityHint("사내 저장소의 릴리즈 페이지를 엽니다")
                    }
                }
            }
        }
    }

    @ViewBuilder private var card: some View {
        switch updates.state {
        case .available(let release):
            box {
                Text("\(release.tag) 이 나왔습니다").captionStyle(.semibold)
                notes(release)
                HStack(spacing: 8) {
                    if updates.canInstall {
                        Button { Task { await updates.install() } } label: {
                            controlBox("설치하고 다시 시작", color: .accentColor, filled: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("새 버전을 받아 설치하고 앱을 다시 시작한다")
                    }
                    Button { updates.openReleaseNotes() } label: { Text("릴리즈 노트") }
                        .buttonStyle(.borderless).captionStyle()
                        .accessibilityHint("사내 저장소의 릴리즈 페이지를 엽니다")
                }
                if let blocked = updates.installBlockedReason {
                    Text(blocked).captionStyle().foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let size = release.sizeText {
                    Text("약 \(size). 받아서 바꿔 넣고 앱이 다시 뜹니다")
                        .captionStyle().foregroundStyle(.tertiary)
                }
            }
        case .downloading(let release, let received, let total):
            box {
                Text("\(release.tag) 받는 중").captionStyle(.semibold)
                // 막대는 여기 한 곳에만 쓴다. 4MB 는 대개 몇 초지만 사내망이
                // 막히면 멈춘 것과 느린 것을 구별할 방법이 이것뿐이다
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                Text(progressText(received: received, total: total))
                    .captionStyle().foregroundStyle(.tertiary)
            }
        case .ready(let release):
            box {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark")
                    Text("\(release.tag) 준비됨").captionStyle(.semibold)
                }
                .foregroundStyle(.green)
                // 단추가 없다. 여기까지 왔으면 사용자가 이미 한 번 눌렀다
                Text("2초 뒤에 clf 가 다시 시작합니다")
                    .captionStyle().foregroundStyle(.tertiary)
            }
        default:
            EmptyView()
        }
    }

    /// 지난 교체가 끝나지 않았다. helper 는 앱이 죽은 뒤에 돌아서 이 로그가
    /// 유일한 단서다.
    @ViewBuilder private var staleNotice: some View {
        if updates.staleLog != nil, case .ready = updates.state {
            EmptyView()
        } else if updates.staleLog != nil {
            HStack(spacing: 4) {
                Text("지난 업데이트가 끝나지 않았습니다")
                    .captionStyle().foregroundStyle(.orange)
                Button("로그 열기") { updates.openStaleLog() }
                    .buttonStyle(.borderless).captionStyle()
            }
        }
    }

    @ViewBuilder private func notes(_ release: Release) -> some View {
        let lines = release.noteLines()
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                // 세 줄까지만 보인다. 전문은 릴리즈 노트로 브라우저에서 본다.
                // 312픽셀 안에 스크롤 영역을 또 만들지 않는다
                ForEach(lines, id: \.self) { line in
                    Text(line).captionStyle().foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Metrics.badgeRadius)
                .fill(Color.primary.opacity(0.04)))
        }
    }

    private func progressText(received: Int64, total: Int64) -> String {
        let mb = { (bytes: Int64) in String(format: "%.1fMB", Double(bytes) / 1_048_576) }
        guard total > 0 else { return mb(received) }
        return "\(mb(received)) / \(mb(total))"
    }

    /// 카드 하나. 설정의 계정 상자와 같은 바탕을 쓴다.
    private func box(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Metrics.boxRadius)
                .fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: Metrics.boxRadius)
                .stroke(Color.primary.opacity(0.10)))
    }
}

/// 이슈와 릴리즈 노트로 가는 문.
///
/// 업데이트 기능과 무관하게 늘 같은 모양으로 있다. 목적지는 전부 사내 GHE 다.
/// docs/design/17-repo-split.html 3절
private struct RepoSection: View {
    let updates: UpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("저장소").subheadStyle(.semibold)
            HStack(spacing: 8) {
                Button { updates.openIssue() } label: {
                    controlBox("이슈 남기기", color: .accentColor, filled: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("사내 저장소에 이슈 남기기")
                Button { updates.openReleases() } label: {
                    controlBox("릴리즈 페이지", color: .accentColor, filled: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("사내 저장소의 릴리즈 목록 열기")
            }
            // 사내망 밖에서는 안 열린다. 그 사실을 미리 말한다. 업데이트 자체는
            // 공개 저장소를 보므로 망과 무관하게 돈다
            Text("이슈와 릴리즈 노트는 사내 저장소에 있습니다. 사내망에서 열립니다")
                .captionStyle().foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 톱니. 새 버전이 있으면 점 하나가 붙는다.
///
/// **점 하나가 전부다.** 숫자도 글자도 붙이지 않는다. 한도를 보러 연 사람의
/// 눈을 업데이트가 가로채면 안 된다. 사용자가 스스로 설정을 열 이유를 만드는
/// 것이 이 점의 전부고, 설정을 한 번 열면 사라진다.
///
/// `updates` 를 관찰해야 확인이 끝난 순간 점이 따라 붙는다. 팝오버를 연 채로
/// 확인이 끝나는 일이 실제로 있다.
private struct GearIcon: View {
    @ObservedObject var updates: UpdateModel
    let open: Bool
    let news: Bool

    var body: some View {
        Image(systemName: open ? "gearshape.fill" : "gearshape")
            .overlay(alignment: .topTrailing) {
                if news {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        // 팝오버 바탕색으로 테두리를 둬서 톱니 획과 안 붙는다
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor),
                                                 lineWidth: 1))
                        .offset(x: 3, y: -2)
                }
            }
    }
}

struct PopoverView: View {
    @ObservedObject var model: UsageModel
    @Environment(\.colorScheme) private var scheme
    @State private var showingSettings = false
    @StateObject private var sharedSessions = SharedSessionModel()

    /// 설정을 펼치면 아래로 자라지 않고 **왼쪽에 열이 하나 붙는다.**
    ///
    /// 아래로 자라던 것이 화면 밖으로 나갔다. 계정 카드 셋에 설정 판을 이어
    /// 붙이면 900점을 넘는데 메뉴바를 뺀 높이가 945점이라, 계정이 하나만 늘거나
    /// 업데이트 카드가 펼쳐지면 하단이 잘린다. 두 열로 가르면 높이가 둘 중 더
    /// 긴 쪽으로 정해진다. 실측으로 434 에서 570 이 됐고 375점이 남는다.
    ///
    /// **팝오버 전체가 왼쪽으로 밀린다.** 창 좌표를 재 보면 닫힌 상태는
    /// `1163..1503` (폭 340) 이고 펼친 상태는 `597..1278` (폭 681) 이다.
    /// 시스템은 상태 항목 왼쪽 끝에 창을 맞추다가 그 폭이 화면 오른쪽을 넘기면
    /// 오른쪽 끝에 맞추는 쪽으로 뒤집는다. 우리가 정할 수 있는 값이 아니다.
    ///
    /// 그래서 새 열을 **왼쪽**에 둔다. 어느 쪽에 두든 창은 같은 자리로 밀리므로
    /// 정할 수 있는 것은 두 열의 차례뿐이다. 설정을 왼쪽에 두면 본문 열의 오른쪽
    /// 끝이 상태 항목 오른쪽 끝과 맞아서 눈이 가 있던 자리 바로 아래에 남는다.
    /// 오른쪽에 뒀다면 본문이 상태 항목에서 566점 떨어진 곳으로 간다.
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if showingSettings {
                settingsColumn
                // 두 열 사이의 칸막이. 열마다 여백 14 가 있어서 선 좌우로
                // 28 이 벌어진다
                Divider()
            }
            mainColumn
        }
        // 라이트는 흰 판, 다크는 재질이다.
        //
        // 킷은 팝오버에 Thick 재질을 쓰고 그 자리가 .thickMaterial 이다.
        // 라이트에서는 그래도 벽지가 배어 나와서 흰 판으로 덮는다. 게이지의
        // 초록과 민트가 흰 바탕 기준으로 맞춰진 값이라 바탕이 흔들리면 그
        // 색들이 같이 흔들린다.
        // docs/design/popover-hig27-applied-mockup.html
        .background {
            if scheme == .dark {
                Rectangle().fill(.thickMaterial)
            } else {
                Color.white
            }
        }
        // esc 로 닫는다. 메뉴는 esc 로 닫히는데 이 창은 안 닫혀서
        // 사용자가 밖을 눌러야 한다
        .escapeToClose()
        .task {
            // 지난 결과는 한 번 읽으면 끝이다. 다시 열면 깨끗한 화면부터
            model.clearNotice()
            // 계정은 로컬 파일이라 공짜다. 열자마자 지금 값을 본다
            await model.refreshActiveNow()
            // 겹친 세션도 로컬 파일이다. 열 때 한 번만 훑는다
            sharedSessions.refresh()
            await model.refresh()
        }
        // 설정 판을 편 채로 닫으면 그 서브트리가 메뉴바에 남는다. 남은 트리는
        // 화면 주사율마다 레이아웃을 다시 돌고, 그 한 바퀴마다 세그먼트 Picker 가
        // 타는 DesignLibrary 경로가 ObservationRegistrar 를 초당 두 개씩 흘린다.
        // 며칠이면 힙이 수백 MB 가 되고 CPU 가 한 코어를 채운다. 닫을 때 접는다
        .onDisappear { showingSettings = false }
    }

    /// 왼쪽 열. 설정만 산다.
    ///
    /// 두 열의 제목 줄이 같은 높이에 서도록 여기도 제목을 한 줄 둔다. 열이
    /// 갑자기 왼쪽에 나타나는데 이름이 없으면 무엇이 열린 것인지 한 박자
    /// 늦게 읽힌다.
    private var settingsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("설정").bodyStyle(.semibold)
                Spacer()
            }
            .calloutStyle()
            .padding(.bottom, 8)

            SettingsPane(model: model)
        }
        .padding(Metrics.popoverPadding)
        .frame(width: Metrics.popoverWidth)
    }

    /// 오른쪽 열. 설정을 여닫아도 이 열은 자리와 폭이 그대로다.
    private var mainColumn: some View {
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
                    GearIcon(updates: model.updates, open: showingSettings,
                             news: model.hasUpdateNews)
                }
                .help(showingSettings ? "설정 닫기" : "설정 열기")
                .accessibilityLabel(showingSettings ? "설정 닫기" : "설정 열기")
                .accessibilityValue(model.hasUpdateNews ? "새 버전 있음" : "")
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

            // 두 열의 길이가 다르다. 짧은 쪽이 이 열이면 남는 자리가 아래에
            // 생기는데, 조작 줄이 허공에 뜨고 그 아래가 비면 창이 잘린 것처럼
            // 보인다. 늘어나는 자리를 여기 두어 조작 줄을 바닥에 붙인다.
            //
            // 최소값이 16 인 이유는 설정을 닫았을 때다. 그때는 이 열이 유일한
            // 열이라 늘어날 자리가 없고, 카드와 조작 줄 사이의 여백이 그대로
            // 16 이어야 한다. docs/design/footer-gap-mockup.html A안
            Spacer(minLength: 16)

            HStack(spacing: 12) {
                Text(model.readAt.map { stamp($0) } ?? "-")
                    .captionStyle().foregroundStyle(.tertiary)
                Spacer()
                // 여기만 테두리를 두른다. 종료까지 단추로 만들면 창을 끄는
                // 쪽이 같은 무게로 올라선다
                Button {
                    // 팝오버를 먼저 닫는다. 열린 채 두면 키 창 자리를 쥐고
                    // 있어서 넘기기 창이 떠도 포커스를 못 받는다. 활성은
                    // 그대로 쥔다. 넘기기 창이 바로 이어서 뜬다
                    AppFocus.dismissPopover(yieldFocus: false)
                    HandoffWindow.open()
                } label: {
                    Label("작업이전/자동재개", systemImage: "arrow.left.arrow.right")
                        .calloutStyle(.medium)
                }
                .glassButton()
                .hoverTip(Copy.handoffHelp)
                .accessibilityLabel("세션 작업을 다른 계정으로 이전하거나 리밋이 풀릴 때 이어 돌린다")
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
        }
        .padding(Metrics.popoverPadding)
        .frame(width: Metrics.popoverWidth)
    }

    private func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date) + " 갱신"
    }
}

/// 이름 옆에 붙는 작은 딱지.
///
/// 팝오버의 플랜(`team`)과 기본 창 표시가 쓰던 것을 창에서도 쓴다. 같은 뜻의
/// 표시가 두 군데서 조금씩 다른 모양이 되면 그때부터 규칙이 아니라 습관이다.
struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .captionStyle(.semibold)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: Metrics.badgeHeight)
            .background(tint.opacity(0.22),
                        in: RoundedRectangle(cornerRadius: Metrics.badgeRadius))
    }
}

/// 화면에 쓰는 긴 안내 문구. 툴팁과 접근성 힌트가 같은 말을 써야 한다.
enum Copy {
    static let handoffHelp = "세션을 다른 계정으로 옮기거나,"
        + " 리밋이 풀리면 CLI 로 이어 돌리도록 예약합니다"
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
