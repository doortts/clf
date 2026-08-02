import AppKit
import Foundation
import SwiftUI
import ClflDesktop

/// 세션 넘기기 창이 보는 상태.
///
/// **대화는 복사하지 않는다.** 420바이트짜리 레코드 파일을 계정 폴더 사이로
/// 옮기는 것이 전부다. 그래서 크기도 진행 상태도 상관없다.
/// docs/design/13-multi-instance.md
@MainActor
final class HandoffModel: ObservableObject {
    /// 고를 수 있는 계정 하나. 이름 옆에 지금 어떤 창을 갖고 있는지 붙는다.
    struct Account: Identifiable, Hashable {
        let uuid: String
        let name: String
        let slot: InstanceSlot
        var id: String { uuid }

        var where_: String {
            switch slot {
            case .primary:     return "기본 창"
            case .running:     return "별도 창 실행중"
            case .opening:     return "여는 중"
            case .none:        return "창 없음"
            case .unavailable: return "창을 못 띄운다"
            }
        }
    }

    @Published var source = ""
    @Published var target = ""
    @Published private(set) var sessions: [SessionSummary] = []
    @Published var picked: Set<String> = []
    @Published private(set) var advice: HandoffAdvice?
    @Published private(set) var failure: String?
    @Published private(set) var working = false

    private let primary: URL
    private let launcher: AltLauncher
    private unowned let usage: UsageModel

    init(usage: UsageModel, primary: URL = DesktopReader.defaultSupportDirectory) {
        self.usage = usage
        self.primary = primary
        self.launcher = AltLauncher(source: primary)
    }

    var accounts: [Account] {
        usage.known.map { org in
            let slug = AltInstance.slug(org.name)
            return Account(uuid: org.uuid, name: org.name,
                           slot: InstanceSlot.of(slug: slug, isPrimary: org.isActive,
                                                 running: usage.running, opening: usage.opening))
        }
    }

    func account(_ uuid: String) -> Account? { accounts.first { $0.uuid == uuid } }

    /// 옮기기 전에 보여줄 안내. 계정이 둘 다 정해져야 만들 수 있다.
    var plan: HandoffPlan? {
        guard let from = account(source), let to = account(target) else { return nil }
        return .before(source: (from.name, from.slot), target: (to.name, to.slot))
    }

    var canMove: Bool {
        !working && !picked.isEmpty && SessionHandoff.canMove(from: source, to: target)
    }

    /// 창을 열 때. 원본은 기본 앱이 지금 쓰는 계정으로 맞춘다.
    func open() {
        advice = nil
        failure = nil
        picked = []
        let all = accounts
        if account(source) == nil {
            source = all.first(where: { $0.slot == .primary })?.uuid ?? all.first?.uuid ?? ""
        }
        if account(target) == nil || target == source {
            target = all.first(where: { $0.uuid != source })?.uuid ?? ""
        }
        reload()
    }

    /// 원본 계정이 가진 세션. 제목은 트랜스크립트 양끝에서 읽는다.
    func reload() {
        picked = []
        guard let account = account(source), let stores = stores(for: account) else {
            sessions = []
            return
        }
        // 같은 세션이 자리마다 있다. 파일 이름으로 하나로 친다
        var seen = Set<String>()
        sessions = stores.flatMap { $0.summaries() }.filter { seen.insert($0.fileName).inserted }
            .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
    }

    private func stores(for account: Account) -> [SessionStore]? {
        guard let person = SessionStore.person(in: primary) else { return nil }
        return SessionHandoff.stores(account: account.uuid, name: account.name,
                                     primary: primary, person: person)
    }

    func toggle(_ fileName: String) {
        if picked.contains(fileName) { picked.remove(fileName) } else { picked.insert(fileName) }
    }

    /// 고른 것을 옮긴다. 막힌 것은 남기고 이유를 말한다.
    func move() {
        guard canMove, let from = account(source), let to = account(target),
              let src = stores(for: from), let dst = stores(for: to)
        else { return }
        working = true
        failure = nil
        advice = nil

        var moved = 0
        var stuck: [String] = []
        for name in picked.sorted() {
            do {
                try SessionHandoff.move(name, from: src, to: dst)
                moved += 1
            } catch {
                stuck.append("\(error)")
            }
        }
        working = false
        failure = stuck.isEmpty ? nil : stuck.joined(separator: "\n")
        if moved > 0 {
            advice = .after(moved: moved, source: (from.name, from.slot),
                            target: (to.name, to.slot))
        }
        reload()
    }

    /// 별도 창을 닫고 다시 띄운다. 목록은 띄울 때 읽으므로 그래야 반영된다.
    func relaunch(_ name: String) {
        guard let account = accounts.first(where: { $0.name == name }),
              let slug = AltInstance.slug(name), let pid = usage.instances[slug]
        else { return }
        working = true
        let launcher = self.launcher
        let uuid = account.uuid
        Task { [weak self] in
            let app = NSRunningApplication(processIdentifier: pid)
            app?.terminate()
            // 앱이 나가면서 파일을 쓴다. 다 나간 뒤에 띄워야 안전하다
            for _ in 0..<50 where !(app?.isTerminated ?? true) {
                try? await Task.sleep(for: .milliseconds(200))
            }
            var ok: String?
            if app?.isTerminated == false {
                ok = "\(name) 창이 안 닫힌다. 직접 닫고 다시 띄운다"
            } else {
                ok = await Task.detached(priority: .userInitiated) { () -> String? in
                    do { _ = try launcher.launch(name: name, uuid: uuid) } catch {
                        return "\(name) 창을 다시 띄우지 못했다. \(error.localizedDescription)"
                    }
                    return nil
                }.value
            }
            await MainActor.run {
                self?.working = false
                self?.failure = ok
                if ok == nil { self?.advice = nil }
            }
        }
    }
}
