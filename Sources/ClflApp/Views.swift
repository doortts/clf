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

/// 조직 하나. 세 줄이 5시간, 주간, 모델별이다.
///
/// docs/design/ui-spec.html 의 팝오버. 리셋 문구는 값 옆이 아니라 아랫줄에
/// 둔다. 한 줄에 넣으면 값과 시각이 눈싸움을 한다.
struct OrgCard: View {
    let org: OrgUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if org.isActive {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                }
                Text(org.name).font(.system(size: 13, weight: .semibold))
                if let plan = org.plan { badge(plan, tint: .accentColor) }
                // 정상은 아무 말도 하지 않는다. 배지가 늘 켜져 있으면 안 읽힌다
                if let band = org.binding?.band, band.isNoteworthy {
                    badge(band.label, tint: band.fillColor)
                }
                Spacer()
                if org.isActive {
                    Text("사용 중").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            if org.limits.isEmpty, let error = org.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
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

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }

    private func row(_ kind: LimitKind, _ limit: UsageLimit?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(kind.label)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                UsageGauge(limit: limit)
            }
            Text(BarText.until(limit?.resetsAt))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.leading, 65)
        }
    }
}

/// 어느 조직을 어떤 차례로 볼지. 팝오버 안에서 접었다 편다.
struct SettingsPane: View {
    @ObservedObject var model: UsageModel

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

            Text("팝오버에는 켜 둔 조직이 전부 나온다")
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
                Text(model.readAt == nil ? "읽는 중" : "볼 조직을 하나도 안 켰다")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(model.orgs.enumerated()), id: \.element.id) { index, org in
                    if index > 0 { Divider() }
                    OrgCard(org: org)
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
        .task { await model.refresh() }
    }

    private func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date) + " 갱신"
    }
}
