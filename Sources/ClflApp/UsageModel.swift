import Foundation
import SwiftUI
import ClflDesktop

/// 메뉴바가 보는 상태 전부.
///
/// 읽기와 설정과 주기를 한 자리에 모은다. 뷰는 여기서 읽기만 한다.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var orgs: [OrgUsage] = []
    @Published private(set) var barOrgs: [OrgUsage] = []
    @Published private(set) var failure: String?
    @Published private(set) var readAt: Date?
    @Published private(set) var refreshing = false
    @Published private(set) var prefs = DesktopPreferences()
    /// 시스템이 쥔 값이라 우리 설정 파일에 없다. 열 때마다 물어본다.
    @Published private(set) var loginItem = LoginItemState.off

    private let reader: DesktopReader
    private let file: DesktopPreferencesFile?
    private var pacer = RefreshPacer()
    private var loop: Task<Void, Never>?
    /// 설정 화면이 보는 목록. 사용량을 못 읽는 조직도 들어간다.
    private(set) var known: [OrgUsage] = []

    init(reader: DesktopReader = DesktopReader()) {
        self.reader = reader
        self.file = try? DesktopPreferencesFile()
        if let file { prefs = file.load() }
        loginItem = LoginItem.state
    }

    /// 켜자마자 한 번 읽고, 그다음은 사용량이 정하는 주기로.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.pacer.currentInterval else { return }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// 팝오버를 열 때와 새로고침 단추를 누를 때. 주기와 무관하게 한 번 더 읽는다.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let snapshot = try await reader.read()
            pacer.observe(snapshot)
            known = snapshot.knownOrgs
            orgs = prefs.apply(to: known)
            barOrgs = prefs.barOrgs(from: known)
            readAt = snapshot.readAt
            failure = nil
        } catch {
            // 이전에 읽은 값은 그대로 둔다. 한 번 실패했다고 화면을 비우면
            // 사용자가 아는 것까지 잃는다
            failure = "\(error)"
        }
    }

    // MARK: 설정

    func setLoginItem(_ enabled: Bool) {
        LoginItem.set(enabled)
        // 우리가 원한 값이 아니라 시스템이 답한 값을 그린다. 등록이 승인 대기로
        // 떨어질 수 있고 그때 켜진 것처럼 보이면 안 된다
        loginItem = LoginItem.state
    }

    func openLoginItemSettings() { LoginItem.openSystemSettings() }

    func setHidden(_ uuid: String, _ value: Bool) {
        prefs.setHidden(uuid, value)
        persist()
    }

    func setBarContent(_ content: BarContent) {
        prefs.barContent = content
        persist()
    }

    func move(_ uuid: String, by offset: Int) {
        var order = prefs.order.isEmpty ? orderedUUIDs() : prefs.order
        guard let from = order.firstIndex(of: uuid) else { return }
        let to = from + offset
        guard order.indices.contains(to) else { return }
        order.swapAt(from, to)
        prefs.order = order
        persist()
    }

    /// 순서를 아직 안 정했으면 지금 보이는 차례가 곧 사용자가 본 차례다.
    private func orderedUUIDs() -> [String] {
        prefs.apply(to: known).map(\.uuid) + known.map(\.uuid).filter { prefs.isHidden($0) }
    }

    private func persist() {
        try? file?.save(prefs)
        orgs = prefs.apply(to: known)
        barOrgs = prefs.barOrgs(from: known)
    }
}
