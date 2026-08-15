import SwiftUI
import ClfDesktop

/// 자동 재개 탭. docs/design/auto-resume-mockup.html
///
/// **실행 단추가 없다.** 지금 당장 돌리고 싶으면 터미널에서 치면 된다. 이 탭은
/// 자동으로 돌 조건을 정하는 자리라 고른 즉시 저장되고, 아랫줄은 닫기 하나다.
struct ResumeTab: View {
    @ObservedObject var draft: ResumeDraft
    /// 상태 상자가 보는 쪽. 초안과 따로 본다.
    ///
    /// 상태는 초안이 아니라 읽기 주기와 실행 결과로 바뀐다. 초안을 통해 값만
    /// 받아오면 창을 열어 둔 채 재개가 끝나도 상자가 안 바뀐다.
    @ObservedObject var resume: AutoResumeDriver
    /// 라이트에서도 읽히는 주의색. 창이 쥐고 있는 것을 그대로 받는다.
    let warnInk: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            head
            // CLI 가 없으면 고를 것도 없다. 못 쓰는 줄을 흐리게 남겨 두는 것보다
            // 빼는 편이 낫다. 무엇이 없어서 못 켜는지는 아래 상자가 말한다
            if draft.canEdit {
                VStack(alignment: .leading, spacing: 5) {
                    count
                    list
                }
                prompt
            }
            status
            authLine
            Spacer(minLength: 0)
            footer
        }
    }

    // MARK: 켜기와 계정

    private var head: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(get: { draft.on },
                                     set: { draft.setOn($0) })) {
                    Text("리밋 풀리면 자동으로 이어 돌리기").font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .disabled(!draft.canEdit)

                Text(draft.canEdit
                     ? "리셋 3분 뒤, 5시간과 주간 잔여가"
                       + " \(AutoResumeWatch.minRemaining)% 이상일 때만 돕니다"
                     : "claude CLI 를 찾지 못했습니다. 설치해야 켤 수 있습니다")
                    .font(.system(size: 10))
                    .foregroundStyle(draft.canEdit ? AnyShapeStyle(.secondary)
                                                         : AnyShapeStyle(warnInk))
                    .fixedSize(horizontal: false, vertical: true)
                    // 체크박스 글자와 맞추는 들여쓰기
                    .padding(.leading, 20)
            }
            if draft.canEdit {
                AccountBox(chosen: draft.chosenAccount,
                           options: draft.accounts,
                           pick: { draft.setAccount($0) },
                           caption: "한도를 지켜볼 계정")
                    .frame(width: 196)
            }
        }
    }

    // MARK: 세션 목록

    /// 어디서 온 목록인지 적는다. 위 탭의 목록과 출처가 달라서 개수만 적으면
    /// 같은 것의 다른 셈으로 읽힌다.
    private var count: some View {
        Text("CLI 세션 \(draft.sessions.count)개")
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 2)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(draft.sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider().opacity(0.4) }
                    row(session)
                }
            }
        }
        .frame(height: Metrics.listHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10)))
        .overlay {
            if draft.sessions.isEmpty {
                Text("이어 돌릴 CLI 세션이 없습니다")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    /// 줄 하나. **동그라미다.** 하나만 고르는 규칙이 눌러보기 전에 보여야 한다.
    /// 이전 탭은 여러 개를 옮기므로 네모다.
    private func row(_ session: CliSession) -> some View {
        let on = draft.session?.id == session.id
        return Button {
            draft.pick(session)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(.system(size: 12)).lineLimit(1)
                    Text(session.folder())
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(BarText.since(session.modifiedAt))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.title) 세션을 이어 돌린다")
    }

    // MARK: 프롬프트

    private var prompt: some View {
        HStack(spacing: 8) {
            Text("프롬프트").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("", text: Binding(get: { draft.prompt },
                                        set: { draft.setPrompt($0) }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .accessibilityLabel("재개할 때 보낼 프롬프트")
        }
    }

    // MARK: 상태

    private var status: some View {
        let state = resume.status
        return NoteBox(accent: ink(state.accent)) {
            WrappedCaption(text: state.text())
        }
    }

    /// CLI 로그인 계정 한 줄.
    ///
    /// 상태 상자와 나눠 둔다. 상자는 **자동 재개가 지금 무엇을 하고 있는지**를
    /// 말하고 이 줄은 **그것이 어느 계정으로 돌지**를 말한다. 한 상자에 넣으면
    /// 실행 결과와 전제가 섞여 어느 쪽이 문제인지 안 갈린다.
    private var authLine: some View {
        let line = draft.authLine
        return HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(ink(line.accent) ?? Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
                // 첫 줄 글자 가운데에 맞춘다
                .padding(.top, 4)
            Text(line.text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }

    private func ink(_ accent: AutoResumeStatus.Accent) -> Color? {
        switch accent {
        case .none: return nil
        case .good: return .green
        case .wait: return warnInk
        case .bad:  return .red
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("닫기") { NSApp.keyWindow?.close() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
