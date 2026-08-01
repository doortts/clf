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

/// 잔여를 막대 하나로. 남은 만큼 채운다.
struct RemainingBar: View {
    let limit: UsageLimit?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                if let limit {
                    Capsule()
                        .fill(limit.band.color)
                        .frame(width: max(2, geo.size.width * Double(limit.percentRemaining) / 100))
                }
            }
        }
        .frame(height: 5)
    }
}

/// 조직 하나. 세 줄이 5시간, 주간 전체, 주간 모델별이다.
struct OrgCard: View {
    let org: OrgUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if org.isActive {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                }
                Text(org.name).font(.system(size: 12, weight: .semibold))
                if let plan = org.plan {
                    Text(plan).font(.system(size: 9))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
                if org.isActive {
                    Text("사용 중").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }

            if let error = org.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                ForEach(LimitKind.allCases, id: \.self) { kind in
                    row(kind, org.limits[kind])
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func row(_ kind: LimitKind, _ limit: UsageLimit?) -> some View {
        HStack(spacing: 8) {
            Text(kind.label)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            RemainingBar(limit: limit).frame(width: 96)
            Text(limit.map { "\($0.percentRemaining)%" } ?? BarText.unknown)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .frame(width: 32, alignment: .trailing)
            Text(BarText.until(limit?.resetsAt))
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .frame(minWidth: 74, alignment: .leading)
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

            Text("팝오버에는 켜 둔 조직이 전부 나온다")
                .font(.system(size: 9)).foregroundStyle(.tertiary)

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
            if let failure = model.failure {
                Text(failure)
                    .font(.system(size: 10)).foregroundStyle(.red)
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
                Button(showingSettings ? "닫기" : "설정") {
                    withAnimation(.easeOut(duration: 0.12)) { showingSettings.toggle() }
                }
                .accessibilityLabel(showingSettings ? "설정 닫기" : "설정 열기")
                Button("새로고침") { Task { await model.refresh() } }
                    .disabled(model.refreshing)
                    .accessibilityLabel("지금 새로고침")
                Spacer()
                Text(model.readAt.map { stamp($0) } ?? "-")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                Button("종료") { NSApplication.shared.terminate(nil) }
                    .accessibilityLabel("clfl 종료")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10))
        }
        .padding(12)
        .frame(width: 320)
        .task { await model.refresh() }
    }

    private func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date) + " 갱신"
    }
}
