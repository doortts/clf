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
        AccountBox(chosen: model.account(selection.wrappedValue),
                   options: model.accounts.filter { $0.uuid != exclude },
                   pick: { selection.wrappedValue = $0 })
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider().opacity(0.4) }
                    row(session)
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

    /// 줄 하나. `onTapGesture` 는 스크롤 뷰 안에서 클릭을 놓친다.
    /// 단추로 만들면 키보드와 보이스오버도 따라온다.
    private func row(_ session: SessionSummary) -> some View {
        let on = model.picked.contains(session.fileName)
        return Button {
            model.toggle(session.fileName)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.display).font(.system(size: 12)).lineLimit(1)
                    Text(session.warning ?? session.folder)
                        .font(.system(size: 10))
                        .foregroundStyle(session.warning == nil ? Color.secondary : Color.yellow)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(BarText.since(session.lastActivityAt))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var note: some View {
        if let failure = model.failure {
            box(Color.red) {
                wrapped(failure)
            }
        } else if let advice = model.advice {
            box(Color.green) {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(advice.moved)개를 옮겼다.")
                            .font(.system(size: 11, weight: .semibold))
                        wrapped(advice.detail)
                    }
                    if !advice.relaunch.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(advice.relaunch, id: \.self) { name in
                                Button("\(name) 창 다시 띄우기") { model.relaunch(name) }
                                    .controlSize(.small)
                                    .disabled(model.working)
                            }
                        }
                    }
                }
            }
        } else if let plan = model.plan {
            // 보낸 쪽에 할 일이 남으면 노란 띠를 세운다. 그냥 설명이 아니라 권고다
            box(plan.sourceNote == nil ? nil : Color.yellow) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(plan.lines, id: \.self) { wrapped($0) }
                }
            }
        } else {
            box(nil) {
                wrapped("계정이 둘은 있어야 넘길 수 있다.")
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
            Button(model.advice == nil ? "취소" : "닫기") { NSApp.keyWindow?.close() }
            Button(model.picked.isEmpty ? "옮기기" : "\(model.picked.count)개 옮기기") {
                model.move()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canMove)
        }
    }
}


/// 계정 상자. 이름 아래 지금 어떤 창을 갖고 있는지 붙는다.
///
/// `Menu` 를 쓰지 않는다. 메뉴 라벨은 뷰를 여럿 줘도 제목 한 줄로 눌려서
/// 두 번째 줄이 사라진다. 그래서 상자는 우리가 그리고 클릭만 `NSMenu` 로
/// 넘긴다. docs/design/handoff-mockup.html
struct AccountBox: View {
    let chosen: HandoffModel.Account?
    let options: [HandoffModel.Account]
    let pick: (String) -> Void

    @State private var anchor: NSView?
    @State private var relay = MenuRelay()

    var body: some View {
        Button(action: showMenu) { box }
            .buttonStyle(.plain)
            .background(MenuAnchor(view: $anchor))
    }

    private var box: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(chosen?.name ?? "계정 없음")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(chosen?.where_ ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
        .contentShape(Rectangle())
    }

    private func showMenu() {
        guard let anchor, !options.isEmpty else { return }
        relay.pick = pick
        let menu = NSMenu()
        for account in options {
            let item = NSMenuItem(title: "\(account.name) - \(account.where_)",
                                  action: #selector(MenuRelay.fire(_:)), keyEquivalent: "")
            item.target = relay
            item.representedObject = account.uuid
            item.state = account.uuid == chosen?.uuid ? .on : .off
            menu.addItem(item)
        }
        // 상자 아래에 붙인다. 좌표계가 뒤집혀 있으면 아래쪽이 반대다
        let below = anchor.isFlipped ? anchor.bounds.height + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: anchor)
    }
}

/// 메뉴 항목은 target/action 을 요구한다. 클로저를 받아 줄 자리가 필요하다.
final class MenuRelay: NSObject {
    var pick: (String) -> Void = { _ in }
    @objc func fire(_ sender: NSMenuItem) {
        pick(sender.representedObject as? String ?? "")
    }
}

/// 메뉴를 어디에 띄울지 알려면 뒤에 있는 NSView 가 필요하다.
///
/// **클릭은 통과시켜야 한다.** 보통 NSView 는 자기 자리에 온 클릭을 가로채서
/// 뒤에 깔면 상자를 눌러도 아무 일이 없다.
private struct MenuAnchor: NSViewRepresentable {
    @Binding var view: NSView?

    final class PassThrough: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let v = PassThrough()
        DispatchQueue.main.async { view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
