import SwiftUI
import ClfDesktop

/// 세션 넘기기 창. docs/design/handoff-mockup.html
struct HandoffView: View {
    @ObservedObject var model: HandoffModel
    /// 자동 재개 탭의 초안. 탭을 오가도 살아 있어야 해서 창이 들고 있다.
    @ObservedObject var draft: ResumeDraft
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 460
    static let listHeight: CGFloat = 180

    /// 주의 글자색.
    ///
    /// 시스템 노랑(#ffcc00)은 어두운 배경에서만 읽힌다. 목록 배경이 흰색에
    /// 가까운 라이트 테마에서는 대비가 1.3 밖에 안 나와 글자가 사라진다.
    /// 라이트에서는 같은 색조를 어둡게 내려 대비 5 를 맞춘다.
    private var warnInk: Color {
        scheme == .dark
            ? Color(red: 1, green: 0.8, blue: 0)
            : Color(red: 0.54, green: 0.32, blue: 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 세션을 다루는 두 일이다. 자동 재개를 설정 패널에 넣으면 켤 때마다
            // 패널이 한 화면을 넘긴다. docs/design/16-auto-resume.md 7절
            Picker("", selection: $model.tab) {
                ForEach(HandoffModel.Tab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.tab {
            case .handoff: handoffTab
            case .resume:  ResumeTab(draft: draft, warnInk: warnInk)
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .onAppear {
            model.open()
            draft.open()
        }
    }

    private var handoffTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            route
            VStack(alignment: .leading, spacing: 5) {
                count
                list
            }
            note
            Spacer(minLength: 0)
            footer
        }
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

    /// 목록에 몇 개가 있는지. 화면에 셋만 보이면 그게 전부인지 알 수 없다.
    ///
    /// 고른 개수는 안 적는다. 아래 단추가 이미 "2개 옮기기" 라고 말한다.
    @ViewBuilder private var count: some View {
        if !model.sessions.isEmpty {
            Text("세션 \(model.sessions.count)개")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider().opacity(0.4) }
                    row(session)
                }
            }
            // 넘칠 때는 막대를 계속 보여준다
            .background(AlwaysVisibleScrollers())
        }
        .frame(height: Self.listHeight)
        // 검정 덮기 대신 라벨색 퍼센트. 라이트에서도 같은 만큼 가라앉는다
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10)))
        .overlay {
            if model.sessions.isEmpty {
                Text("이 계정에는 세션이 없습니다")
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
                    // 폴더와 경고를 한 줄에 같이 적는다. 경고만 색을 준다
                    detailLine(session)
                        .font(.system(size: 10))
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
        } else if let note = model.shareNote {
            box(Color.green) { wrapped(note) }
        } else if let advice = model.advice {
            box(Color.green) {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(advice.moved)개를 옮겼습니다.")
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
            box(plan.sourceNote == nil ? nil : warnInk) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(plan.lines, id: \.self) { wrapped($0) }
                }
            }
        } else {
            box(nil) {
                wrapped("계정이 둘은 있어야 넘길 수 있습니다.")
            }
        }
    }

    /// 제목 아래 한 줄. 폴더는 늘 보조색이고 경고 부분만 주의색이다.
    /// 문자열을 합쳐 색 하나로 칠하면 폴더까지 노래진다.
    private func detailLine(_ session: SessionSummary) -> Text {
        let folder = Text(session.folder).foregroundColor(.secondary)
        guard let warning = session.warning else { return folder }
        let warn = Text(warning).foregroundColor(warnInk)
        guard !session.folder.isEmpty else { return warn }
        return folder + Text(" - ").foregroundColor(.secondary) + warn
    }

    /// 안내는 접어서 다 보여준다. 한 줄로 자르면 뒷말이 사라진다.
    private func wrapped(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
    }

    private func box(_ accent: Color?,
                     @ViewBuilder content: @escaping () -> some View) -> some View {
        NoteBox(accent: accent, content: content)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button(model.advice == nil && model.shareNote == nil ? "취소" : "닫기") {
                NSApp.keyWindow?.close()
            }
            // 끊기는 이미 공유해 둔 것을 골랐을 때만 나온다. 늘 두면 단추가
            // 넷이고 대개는 쓸 일이 없다
            if model.canUnshare {
                Button("공유 끊기") { model.unshare() }
            }
            Button("양쪽에 두기") { model.share() }
                .disabled(!model.canMove)
            Button(model.picked.isEmpty ? "옮기기" : "\(model.picked.count)개 옮기기") {
                model.move()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canMove)
        }
    }
}


/// 목록이 넘치면 스크롤 막대를 계속 보여준다.
///
/// `.scrollIndicators(.visible)` 로는 안 된다. 시스템 설정의 "스크롤 막대
/// 보기" 기본값이 "스크롤할 때" 라서 SwiftUI 의 요청보다 앞선다. 이 창
/// 하나에서만 뒤집으려면 감싸는 `NSScrollView` 를 찾아 legacy 로 바꾼다.
/// legacy 막대는 겹치지 않고 자리를 차지하므로 안 넘칠 때는 안 보인다.
private struct AlwaysVisibleScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        // 뷰 계층은 makeNSView 시점에 아직 안 붙어 있다. 다음 사이클에 찾는다
        DispatchQueue.main.async {
            var view: NSView? = probe
            while let v = view, !(v is NSScrollView) { view = v.superview }
            guard let scroll = view as? NSScrollView else { return }
            scroll.scrollerStyle = .legacy
            scroll.autohidesScrollers = true
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 창 아래에 붙는 안내 상자. 두 탭이 같은 꼴을 쓴다.
///
/// 왼쪽 색 띠는 눈길을 끌 이유가 있을 때만 세운다. 늘 세우면 색이 뜻을 잃는다.
struct NoteBox<Content: View>: View {
    let accent: Color?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            if let accent { Rectangle().fill(accent).frame(width: 2) }
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}

/// 접어서 다 보여준다. 한 줄로 자르면 뒷말이 사라진다.
struct WrappedCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
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
    /// 이름 아래 줄을 갈아 끼운다.
    ///
    /// 작업 이전 탭에서는 그 계정이 지금 어떤 창을 갖고 있는지가 판단 근거다.
    /// 자동 재개 탭에서는 창과 무관하고 **그 계정이 무슨 역할인지**가 헷갈리는
    /// 자리다. 바로 아래 목록이 CLI 세션이라 실행 계정으로 읽히기 쉽다.
    var caption: String?

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
                Text(caption ?? chosen?.where_ ?? "")
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
