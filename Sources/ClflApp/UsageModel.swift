import AppKit
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
    /// 막대에 올릴 그림. 색을 살리려면 이미지여야 한다.
    @Published private(set) var barImage: NSImage?
    @Published private(set) var failure: String?
    @Published private(set) var readAt: Date?
    @Published private(set) var refreshing = false
    /// 지금 눌러도 안 읽는 이유. 눌러도 아무 일이 없으면 고장 난 것으로 보인다.
    @Published private(set) var waitText: String?
    @Published private(set) var prefs = DesktopPreferences()
    /// 시스템이 쥔 값이라 우리 설정 파일에 없다. 열 때마다 물어본다.
    @Published private(set) var loginItem = LoginItemState.off

    private let reader: DesktopReader
    private let file: DesktopPreferencesFile?
    private var pacer = RefreshPacer()
    private var gate = ReadGate()
    /// 조직 이름은 안 바뀐다. 매번 물으면 읽기당 요청이 하나씩 더 는다.
    private var cachedNames: [String: String] = [:]
    private var loop: Task<Void, Never>?
    private var orgWatch: Task<Void, Never>?
    private var appearanceWatch: (any NSObjectProtocol)?
    private var activeUUID: String?
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
        watchAppearance()
        watchActiveOrg()
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(scheduled: true)
                guard let interval = self?.pacer.currentInterval else { return }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        orgWatch?.cancel()
        orgWatch = nil
    }

    /// 앱에서 조직을 바꾸면 곧바로 따라간다.
    ///
    /// 활성 조직은 로컬 쿠키에 있어 **네트워크를 안 타므로 자주 물어도 된다.**
    /// 사용량 주기(5분)를 기다리면 메뉴바가 한참 옛 조직을 가리킨다.
    ///
    /// 바뀌면 표시부터 옮기고 숫자는 나중에 맞춘다. 표시는 공짜고 숫자는
    /// 요청이 조직 수만큼 나가기 때문이다.
    private func watchActiveOrg() {
        guard orgWatch == nil else { return }
        let reader = self.reader
        orgWatch = Task { [weak self] in
            while !Task.isCancelled {
                let uuid = await Task.detached(priority: .utility) {
                    reader.activeOrgUUID()
                }.value
                await self?.applyActiveOrg(uuid)
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private func applyActiveOrg(_ uuid: String?) async {
        guard uuid != activeUUID else { return }
        let first = activeUUID == nil
        activeUUID = uuid

        known = reassignActive(to: uuid, in: known)
        orgs = prefs.apply(to: known)
        barOrgs = prefs.barOrgs(from: known)
        barImage = BarImage.render(orgs: barOrgs, detail: prefs.barDetail)

        // 첫 관측은 전환이 아니다. 시작할 때 도는 읽기와 겹치면 요청만 두 배다
        guard !first else { return }
        await refresh(scheduled: true)
    }

    /// 라이트와 다크를 오가면 막대 그림을 다시 구워야 한다. 색이 구울 때
    /// 박히므로 그냥 두면 배경과 같은 색 글씨가 남는다.
    private func watchAppearance() {
        guard appearanceWatch == nil else { return }
        appearanceWatch = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            // 알림이 외양 반영보다 먼저 오는 경우가 있다. 한 틱 뒤에 굽는다
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                self?.redrawBar()
            }
        }
    }

    private func redrawBar() {
        barImage = BarImage.render(orgs: barOrgs, detail: prefs.barDetail)
    }

    /// 팝오버를 열 때, 새로고침을 누를 때, 그리고 주기 루프가 부를 때.
    ///
    /// **읽기 하나에 요청이 조직 수만큼 나간다.** 팝오버를 여닫을 때마다
    /// 읽으면 몇 번 만에 429 가 온다. 그래서 문을 하나 둔다.
    func refresh(scheduled: Bool = false) async {
        guard !refreshing else { return }
        let now = Date()
        guard gate.allows(at: now, scheduled: scheduled) else {
            // 정숙 구간이면 아무 말도 안 한다. 429 일 때만 사유가 뜬다
            waitText = gate.complaint(at: now)
            return
        }
        refreshing = true
        defer { refreshing = false }
        do {
            let snapshot = try await reader.read(names: cachedNames)
            pacer.observe(snapshot)
            gate.record(at: now, throttled: snapshot.throttled)
            waitText = gate.complaint(at: now)

            // 못 읽은 조직에는 지난번 값을 물려준다. 한 번 실패했다고 화면을
            // 비우면 사용자가 알고 있던 것까지 잃는다
            known = mergeKeepingLastGood(fresh: snapshot.knownOrgs, previous: known)
            if !snapshot.names.isEmpty { cachedNames = snapshot.names }
            orgs = prefs.apply(to: known)
            barOrgs = prefs.barOrgs(from: known)
            barImage = BarImage.render(orgs: barOrgs, detail: prefs.barDetail)
            if !snapshot.throttled { readAt = snapshot.readAt }
            failure = nil
        } catch {
            gate.record(at: now, throttled: false)
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

    func setBarDetail(_ detail: BarDetail) {
        prefs.barDetail = detail
        persist()
    }

    private func persist() {
        try? file?.save(prefs)
        orgs = prefs.apply(to: known)
        barOrgs = prefs.barOrgs(from: known)
        barImage = BarImage.render(orgs: barOrgs, detail: prefs.barDetail)
    }
}
