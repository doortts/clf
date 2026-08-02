import SwiftUI
import ClflDesktop

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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // 기본 인스턴스가 쓰는 계정은 악센트 점을 붙인다. 빨강은 이
                // 화면에서 소진이라 강조로 쓰면 위험 신호로 읽힌다.
                // docs/design/popover-hig-mockup.html
                if slot == .primary {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                }
                Text(org.name).font(.system(size: 13, weight: .semibold))
                if let plan = org.plan { badge(plan, tint: .accentColor) }
                // 정상은 아무 말도 하지 않는다. 배지가 늘 켜져 있으면 안 읽힌다
                if let band = org.binding?.band, band.isNoteworthy {
                    badge(band.label, tint: band.fillColor)
                }
                // 창이 떠 있다는 상태. 동작은 오른쪽 단추가 맡는다
                if let state = slot.badgeLabel { runningBadge(state) }
                Spacer(minLength: 6)
                slotControl
            }

            if !org.hasUsage, let error = org.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let spend = org.spend, org.limits.isEmpty {
                // Enterprise 는 시간 창이 없다. 없는 창 셋을 억지로 그리지 않는다
                budgetRow(spend)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(LimitKind.allCases, id: \.self) { kind in
                        row(kind, org.limits[kind])
                    }
                }
                // 값은 옛것이고 사유는 새것이다. 값만 보여주면 사용자가
                // 옛 값을 지금 값으로 믿는다
                if org.isStale, let error = org.error {
                    Text("갱신 못 함. \(error)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 10)
        // 방금까지 보던 창의 계정이 한눈에 잡히게 카드를 깐다. 보라는
        // 이 카드 전용이다. 점, 배지, 메뉴바 밑줄의 파랑(악센트)과
        // 색을 갈라 카드만 "방금 그 창" 을 말한다.
        // docs/design/focus-card-purple-mockup.html
        .background {
            if focused {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.purple.opacity(0.15))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.purple.opacity(0.60), lineWidth: 1)
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
        case .none:
            Button(slot.actionLabel ?? "") { onLaunch?() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 10, weight: .semibold))
                .accessibilityLabel("\(org.name) 계정으로 새 창 띄우기")
        case .running:
            Button(slot.actionLabel ?? "") { onFocus?() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 10, weight: .medium))
                .accessibilityLabel("\(org.name) 창을 앞으로")
        case .opening:
            statusBox(slot.label, tint: .secondary)
        case .primary, .unavailable:
            statusBox(slot.label, tint: .secondary)
        }
    }

    private func statusBox(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(tint.opacity(0.22))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(tint.opacity(0.5), lineWidth: 1)
                    }
            }
    }

    /// 창이 떠 있다는 상태 배지. 노란 점이 창을 뜻한다.
    private func runningBadge(_ text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(Color.yellow).frame(width: 5, height: 5)
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Color.yellow)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
    }

    /// 월 예산 한 줄. 리셋 자리에는 쓴 금액과 한도를 적는다.
    private func budgetRow(_ spend: SpendUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text("월 예산")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                UsageGauge(spend: spend, direction: direction)
            }
            Text("\(spend.usedText) / \(spend.limitText) 사용")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.leading, 65)
        }
    }

    private func row(_ kind: LimitKind, _ limit: UsageLimit?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(kind.label)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                UsageGauge(limit: limit, direction: direction)
            }
            Text(BarText.reset(limit?.resetsAt, window: kind.window, direction: direction))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
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
            VStack(alignment: .leading, spacing: 5) {
                Text("지울 것").font(.system(size: 10, weight: .semibold))
                Text(plan.summary)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(plan.consequence)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
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
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Button { model.previewPurge() } label: {
                    boxLabel("멀티 인스턴스 정보 삭제", color: .red, filled: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("새 창용 데이터 디렉토리 삭제")

                Text("~/.claude-alt-* 를 지운다. 떠 있는 창의 것은 남는다")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        // 결과는 누른 자리 바로 아래 둔다. 위에 있으면 눈이 안 간다
        if let notice = model.instanceNotice {
            Text(notice)
                .font(.system(size: 10)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    /// 세그먼트 왼쪽에 붙는 좁은 라벨 열.
    private func settingRow(_ label: String,
                            @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            content()
        }
    }

    private func boxLabel(_ text: String, color: Color, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(filled ? color : color.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(filled ? .clear : color.opacity(0.45), lineWidth: 1)
                    }
            }
    }

    /// 계정 한 줄. 켜고 끄고 차례를 바꾼다.
    private func accountRow(_ org: OrgUsage) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { !model.prefs.isHidden(org.uuid) },
                set: { model.setHidden(org.uuid, !$0) }
            )) {
                Text(org.name).font(.system(size: 11))
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
        .font(.system(size: 10))
    }

    /// 범위를 고르는 칸과 계정 목록은 한 가지를 정하는 짝이다. 떼어 놓으면
    /// 목록이 무엇을 정하는지 안 보인다. docs/design/settings-group-mockup.html
    private var barAccountsGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("메뉴바에 표시할 계정")
                .font(.system(size: 11, weight: .semibold))

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
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.top, 5)

                Divider().padding(.vertical, 9)

                ForEach(model.known) { org in accountRow(org) }

                // 목록이 막대를 정하는지 아닌지가 고른 칸에 따라 다르다
                Text(model.prefs.barContent.listNote)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.10)))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            barAccountsGroup

            Divider()

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

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: Binding(
                    get: { model.loginItem.isChecked },
                    set: { model.setLoginItem($0) }
                )) {
                    Text(model.loginItem.label).font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .disabled(!model.loginItem.isToggleable)

                if let hint = model.loginItem.hint {
                    HStack(spacing: 4) {
                        Text(hint).font(.system(size: 10)).foregroundStyle(.secondary)
                        if model.loginItem == .needsApproval {
                            // 경로를 말로 설명하는 것보다 열어주는 편이 낫다
                            Button("열기") { model.openLoginItemSettings() }
                                .buttonStyle(.borderless).font(.system(size: 10))
                                .accessibilityLabel("로그인 항목 설정 열기")
                        }
                    }
                    .padding(.leading, 18)
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
    @StateObject private var overlap = OverlapModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("clfl").font(.system(size: 13, weight: .semibold))
                // 숫자가 어느 기준인지 연 순간 알린다. 항상 떠 있는 표시라
                // 눈길을 끌면 안 된다. docs/design/header-direction-mockup.html
                Text("\(model.prefs.gaugeDirection.label) 기준")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.refreshing)
                .accessibilityLabel("지금 새로고침")
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { showingSettings.toggle() }
                } label: {
                    Image(systemName: showingSettings ? "gearshape.fill" : "gearshape")
                }
                .accessibilityLabel(showingSettings ? "설정 닫기" : "설정 열기")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .padding(.bottom, 8)

            if let failure = model.failure {
                Text(failure)
                    .font(.system(size: 10)).foregroundStyle(.red)
                    .padding(.bottom, 6)
            }
            if let wait = model.waitText {
                Text("요청이 몰려 쉬는 중. \(wait) 다시 읽는다")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }

            if model.orgs.isEmpty {
                Text(model.readAt == nil ? "읽는 중" : "볼 계정을 하나도 안 켰다")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.vertical, 10)
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

            // 겹칠 때만 나타난다. 폴더마다 세션이 하나뿐인 평소에는 없다
            OverlapSection(model: overlap, names: model.accountNames)

            if showingSettings {
                SettingsPane(model: model)
                    .padding(.top, 10)
                Divider().padding(.vertical, 6)
            }

            HStack(spacing: 10) {
                Text(model.readAt.map { stamp($0) } ?? "-")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                // 여기만 테두리를 두른다. 종료까지 단추로 만들면 창을 끄는
                // 쪽이 같은 무게로 올라선다
                Button {
                    // 팝오버를 먼저 닫는다. 열린 채 두면 키 창 자리를 쥐고
                    // 있어서 넘기기 창이 떠도 포커스를 못 받는다
                    NSApp.keyWindow?.close()
                    HandoffWindow.open()
                } label: {
                    Label("세션 작업 이전하기", systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .hoverTip(Copy.handoffHelp)
                .accessibilityLabel("세션 작업을 다른 계정으로 이전한다")
                .accessibilityHint(Copy.handoffHelp)
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("종료", systemImage: "power")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("clfl 종료")
            }
            .buttonStyle(.borderless)
        }
        .padding(Metrics.popoverPadding)
        .frame(width: Metrics.popoverWidth)
        .task {
            // 지난 결과는 한 번 읽으면 끝이다. 다시 열면 깨끗한 화면부터
            model.clearNotice()
            // 계정은 로컬 파일이라 공짜다. 열자마자 지금 값을 본다
            await model.refreshActiveNow()
            // 겹치는 폴더도 로컬 파일이다. 열 때 한 번만 훑는다
            overlap.refresh()
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
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(Color.primary.opacity(0.14)))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            // 툴팁이 클릭을 가로채면 단추가 안 눌린다
            .allowsHitTesting(false)
    }
}

extension View {
    func hoverTip(_ text: String) -> some View { modifier(HoverTip(text: text)) }
}
