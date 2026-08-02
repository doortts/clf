import SwiftUI
import ClflDesktop

/// 세션 넘기기 창. docs/design/handoff-mockup.html
struct HandoffView: View {
    @ObservedObject var model: HandoffModel

    static let width: CGFloat = 460
    static let listHeight: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("고른 세션이 어느 계정 것인지만 바꾼다. 대화 내용은 그대로 있다.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            route
            list
            note
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
        .frame(width: Self.width)
        .onAppear { model.open() }
    }

    private var route: some View {
        HStack(spacing: 10) {
            picker(selection: $model.source, exclude: nil)
            Text("->").foregroundStyle(.secondary).font(.system(size: 12, weight: .medium))
            picker(selection: $model.target, exclude: model.source)
        }
        .onChange(of: model.source) { _ in model.reload() }
    }

    private func picker(selection: Binding<String>, exclude: String?) -> some View {
        let chosen = model.account(selection.wrappedValue)
        return Menu {
            ForEach(model.accounts.filter { $0.uuid != exclude }) { account in
                Button {
                    selection.wrappedValue = account.uuid
                } label: {
                    Text("\(account.name) - \(account.where_)")
                }
            }
        } label: {
            // 메뉴 라벨은 뷰를 여럿 주면 첫 줄만 남는다. 이어 붙인 Text 는 산다
            (Text(chosen?.name ?? "계정 없음").font(.system(size: 12, weight: .semibold))
                + Text("  " + (chosen?.where_ ?? "")).font(.system(size: 10))
                    .foregroundColor(.secondary))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.sessions) { session in
                    row(session)
                    Divider().opacity(0.4)
                }
            }
        }
        .frame(height: Self.listHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10)))
        .overlay {
            if model.sessions.isEmpty {
                Text("이 계정에는 세션이 없다")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ session: SessionSummary) -> some View {
        let on = model.picked.contains(session.fileName)
        return HStack(spacing: 10) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 1) {
                Text(session.display).font(.system(size: 12)).lineLimit(1)
                Text(session.hasTranscript ? session.folder : "기록 없음 - 옮겨도 빈 세션이다")
                    .font(.system(size: 10))
                    .foregroundStyle(session.hasTranscript ? Color.secondary : Color.yellow)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(BarText.since(session.lastActivityAt))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(on ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(session.fileName) }
    }

    @ViewBuilder private var note: some View {
        if let failure = model.failure {
            box(Color.red) {
                wrapped(failure)
            }
        } else if let advice = model.advice {
            box(Color.green) {
                VStack(alignment: .leading, spacing: 6) {
                    wrapped(advice.text)
                    if !advice.relaunch.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(advice.relaunch, id: \.self) { name in
                                Button("\(name) 창 다시 띄우기") { model.relaunch(name) }
                                    .font(.system(size: 11))
                                    .disabled(model.working)
                            }
                        }
                    }
                }
            }
        } else {
            box(nil) {
                wrapped(plan)
            }
        }
    }

    /// 안내는 접어서 다 보여준다. 한 줄로 자르면 뒷말이 사라진다.
    private func wrapped(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
    }

    private var plan: String {
        guard let from = model.account(model.source), let to = model.account(model.target)
        else { return "계정이 둘은 있어야 넘길 수 있다." }
        return "옮기면 \(from.name) 목록에서 빠지고 \(to.name) 에 나타난다. "
            + "한 계정만 그 대화를 가리키므로 두 창이 같은 파일을 함께 쓰는 일이 없다."
    }

    private func box(_ accent: Color?, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            if let accent { Rectangle().fill(accent).frame(width: 2) }
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("닫기") { NSApp.keyWindow?.close() }
            Button(model.picked.isEmpty ? "옮기기" : "\(model.picked.count)개 옮기기") {
                model.move()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canMove)
        }
    }
}

