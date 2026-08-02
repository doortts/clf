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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // 기본 인스턴스가 쓰는 계정은 이름 자체를 칠한다
                if slot == .primary {
                    Text(org.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 5))
                } else {
                    Text(org.name).font(.system(size: 13, weight: .semibold))
                }
                if let plan = org.plan { badge(plan, tint: .accentColor) }
                // 정상은 아무 말도 하지 않는다. 배지가 늘 켜져 있으면 안 읽힌다
                if let band = org.binding?.band, band.isNoteworthy {
                    badge(band.label, tint: band.fillColor)
                }
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
        // 낡은 값임을 눈으로도 알린다
        .opacity(org.isStale ? 0.62 : 1)
    }

    /// 상태는 사각형, 행동은 채운 단추. 모양으로 역할이 갈린다.
    @ViewBuilder private var slotControl: some View {
        switch slot {
        case .none:
            Button { onLaunch?() } label: {
                Text(slot.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(org.name) 계정으로 새 창 띄우기")
        case .running:
            // 상태이면서 누를 수 있다. 눌러 그 창을 앞으로 꺼낸다
            Button { onFocus?() } label: {
                statusBox(slot.label, tint: .yellow, filled: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(org.name) 창을 앞으로")
        case .opening:
            statusBox(slot.label, tint: .secondary, filled: false)
        case .primary, .unavailable:
            statusBox(slot.label, tint: .secondary, filled: false)
        }
    }

    private func statusBox(_ text: String, tint: Color, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(filled ? .black : tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 3)
                    .fill(filled ? tint : tint.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(filled ? .clear : tint.opacity(0.5), lineWidth: 1)
                    }
            }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
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
            Text(BarText.reset(limit?.resetsAt))
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
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
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
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
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

    private func boxLabel(_ text: String, color: Color, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(filled ? color : color.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(filled ? .clear : color.opacity(0.45), lineWidth: 1)
                    }
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("막대", selection: Binding(
                get: { model.prefs.barContent },
                set: { model.setBarContent($0) }
            )) {
                ForEach(BarContent.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("자세히", selection: Binding(
                get: { model.prefs.barDetail },
                set: { model.setBarDetail($0) }
            )) {
                ForEach(BarDetail.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("퍼센트", selection: Binding(
                get: { model.prefs.gaugeDirection },
                set: { model.setGaugeDirection($0) }
            )) {
                ForEach(GaugeDirection.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("팝오버에는 켜 둔 계정이 전부 나온다. 색은 잔여 기준 그대로다")
                .font(.system(size: 9)).foregroundStyle(.tertiary)

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
                        Text(hint).font(.system(size: 9)).foregroundStyle(.secondary)
                        if model.loginItem == .needsApproval {
                            // 경로를 말로 설명하는 것보다 열어주는 편이 낫다
                            Button("열기") { model.openLoginItemSettings() }
                                .buttonStyle(.borderless).font(.system(size: 9))
                                .accessibilityLabel("로그인 항목 설정 열기")
                        }
                    }
                    .padding(.leading, 18)
                }
            }

            Divider()

            // 새 창을 띄우면 계정마다 300MB 쯤 쌓인다. 지울 자리가 필요하다
            purgeSection

            Divider()

            ForEach(model.known) { org in
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
                .font(.system(size: 9))
            }
        }
    }
}

struct PopoverView: View {
    @ObservedObject var model: UsageModel
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("clfl").font(.system(size: 13, weight: .semibold))
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
                ForEach(Array(model.orgs.enumerated()), id: \.element.id) { index, org in
                    if index > 0 { Divider() }
                    OrgCard(org: org, direction: model.prefs.gaugeDirection, slot: model.slot(org),
                            onLaunch: { model.launch(org) },
                            onFocus: { model.focus(org) })
                }
            }

            Divider().padding(.vertical, 4)

            if showingSettings {
                SettingsPane(model: model)
                Divider().padding(.vertical, 6)
            }

            HStack(spacing: 10) {
                Text(model.readAt.map { stamp($0) } ?? "-")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Button { HandoffWindow.open() } label: {
                    Label("세션 넘기기", systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .medium))
                }
                .accessibilityLabel("세션을 다른 계정으로 넘긴다")
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
            await model.refresh()
        }
    }

    private func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date) + " 갱신"
    }
}
