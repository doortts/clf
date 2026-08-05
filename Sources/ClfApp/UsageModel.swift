import AppKit
import Foundation
import SwiftUI
import ClfDesktop

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
    /// 별도 창이 떠 있는 계정과 그 인스턴스의 pid.
    @Published private(set) var instances: [String: Int32] = [:]
    var running: Set<String> { Set(instances.keys) }
    /// 계정 uuid -> 이름. 겹침 목록이 세션의 계정을 이름으로 말할 때 쓴다.
    var accountNames: [String: String] {
        Dictionary(orgs.map { ($0.uuid, $0.name) }, uniquingKeysWith: { a, _ in a })
    }
    /// 띄우는 중인 계정. 245MB 를 푸느라 십수 초 걸린다.
    @Published private(set) var opening: Set<String> = []
    /// 창을 띄우거나 지운 결과. 팝오버를 다시 열면 사라진다.
    @Published private(set) var instanceNotice: String?
    /// 삭제 확인을 기다리는 중. 되돌릴 수 없어서 먼저 보여준다.
    @Published private(set) var purgePlan: PurgePlan?

    private let reader: DesktopReader
    private let file: DesktopPreferencesFile?
    private var pacer = RefreshPacer()
    private var gate = ReadGate()
    /// 계정 이름은 안 바뀐다. 매번 물으면 읽기당 요청이 하나씩 더 는다.
    private var cachedNames: [String: String] = [:]
    private var loop: Task<Void, Never>?
    private var orgWatch: Task<Void, Never>?
    /// 남은 시간 표기를 흐르게 하는 1분 시계.
    private var clock: Task<Void, Never>?
    private let launcher = AltLauncher()
    private let notifier = Notifier()
    /// 알림 권한 상태. 설정 화면이 이걸 보고 안내를 붙인다.
    @Published private(set) var notifyPermission = Notifier.Permission.unknown
    /// 앱을 켠 뒤 한 번이라도 알림을 판단했나. 첫 읽기는 표시만 하고 안 보낸다.
    private var notifiedOnce = false
    private var appearanceWatch: (any NSObjectProtocol)?
    private var spaceWatch: (any NSObjectProtocol)?
    /// 마지막으로 구울 때의 메뉴바 밝기. 바뀌면 다시 굽는다.
    private var barWasDark: Bool?
    private var activeUUID: String?
    /// 앞에 있는 앱. 어느 계정 창인지는 FocusMark 가 답한다.
    private var focusWatch: (any NSObjectProtocol)?
    private var frontPid: Int32?
    private var frontExecutable: String?
    /// 설정 화면이 보는 목록. 사용량을 못 읽는 계정도 들어간다.
    private(set) var known: [OrgUsage] = []

    init(reader: DesktopReader = DesktopReader()) {
        self.reader = reader
        self.file = try? DesktopPreferencesFile()
        if let file { prefs = file.load() }
        loginItem = LoginItem.state
    }

    /// 켜자마자 한 번 읽고, 그다음은 사용량이 정하는 주기로.
    func start() {
        Task { [weak self] in
            guard let self else { return }
            await self.notifier.refreshPermission()
            // 알림이 켜져 있는데 아직 물어본 적이 없으면 지금 물어본다. 기본값이
            // 켜짐이라 이 자리가 없으면 켜 둔 채로 아무 알림도 안 온다
            let ask = await MainActor.run {
                self.syncNotifyPermission()
                return self.prefs.notify && self.notifyPermission == .unknown
            }
            if ask {
                await self.notifier.request()
                await MainActor.run { self.syncNotifyPermission() }
            }
        }
        watchAppearance()
        watchMenuBarBrightness()
        watchFrontApp()
        watchActiveOrg()
        watchClock()
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
        clock?.cancel()
        clock = nil
    }

    /// 앱에서 계정을 바꾸면 곧바로 따라간다.
    ///
    /// 활성 계정은 로컬 쿠키에 있어 **네트워크를 안 타므로 자주 물어도 된다.**
    /// 사용량 주기(5분)를 기다리면 메뉴바가 한참 옛 계정을 가리킨다.
    ///
    /// 바뀌면 표시부터 옮기고 숫자는 나중에 맞춘다. 표시는 공짜고 숫자는
    /// 요청이 계정 수만큼 나가기 때문이다.
    private func watchActiveOrg() {
        guard orgWatch == nil else { return }
        let reader = self.reader
        orgWatch = Task { [weak self] in
            while !Task.isCancelled {
                let (uuid, live) = await Task.detached(priority: .utility) {
                    (reader.activeOrgUUID(), AltInstance.scanInstances())
                }.value
                await MainActor.run {
                    self?.setInstances(live)
                    // 벽지가 바뀌면 알림이 없다. 여기서 같이 확인한다
                    self?.redrawIfBrightnessChanged()
                }
                await self?.applyActiveOrg(uuid)
                await self?.mirrorBackAll()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    /// 어느 계정에 창이 떠 있는지. 로컬 프로세스만 보므로 공짜다.
    func slot(_ org: OrgUsage) -> InstanceSlot {
        InstanceSlot.of(slug: AltInstance.slug(org.name),
                        isPrimary: org.uuid == activeUUID,
                        running: running, opening: opening)
    }

    /// 그 계정 전용 인스턴스를 띄운다.
    ///
    /// 창이 실제로 뜰 때까지 `여는 중` 으로 둔다. 표시가 없으면 사용자가 또
    /// 누르고 인스턴스가 둘이 된다.
    func launch(_ org: OrgUsage) {
        guard slot(org).isActionable, let slug = AltInstance.slug(org.name) else { return }
        opening.insert(slug)
        instanceNotice = nil
        let launcher = self.launcher
        let uuid = org.uuid
        let name = org.name
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try launcher.launch(name: name, uuid: uuid)
                }.value
            } catch {
                await MainActor.run {
                    self?.opening.remove(slug)
                    self?.instanceNotice = "\(name) 창을 못 띄웠다. \(error)"
                }
                return
            }
            // 뜰 때까지 지켜본다. 안 뜨면 60초 뒤 표시를 거둔다
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(2))
                let live = await Task.detached { AltInstance.scanInstances() }.value
                let done = await MainActor.run { () -> Bool in
                    self?.setInstances(live)
                    guard let pid = live[slug] else { return false }
                    self?.opening.remove(slug)
                    // 띄웠으면 앞으로 꺼내 준다. 뒤에 숨어 뜨면 안 뜬 줄 안다
                    AppFocus.bringToFront(pid: pid)
                    return true
                }
                if done { return }
            }
            await MainActor.run {
                self?.opening.remove(slug)
                self?.instanceNotice = "\(name) 창이 안 떴다"
            }
        }
    }

    /// 별도 창에서 한 작업을 기본 인스턴스에도 보이게 한다.
    ///
    /// 기본 창에서 그 계정으로 바꾸면 그때 목록에 나타난다. 앱이 계정을 바꿀
    /// 때 세션 디렉토리를 다시 읽기 때문이다.
    private func mirrorBackAll() async {
        let launcher = self.launcher
        let targets = known.compactMap { org -> (String, String)? in
            guard let slug = AltInstance.slug(org.name), instances[slug] != nil else { return nil }
            return (org.uuid, org.name)
        }
        guard !targets.isEmpty else { return }
        await Task.detached(priority: .utility) {
            for (uuid, name) in targets { launcher.mirrorBack(account: uuid, name: name) }
        }.value
    }

    /// 팝오버를 열었을 때 곧바로 계정을 다시 본다.
    ///
    /// 감시 루프는 5초마다 도는데, 그 사이에 열면 최대 5초 동안 옛 계정이
    /// 보인다. 로컬 파일만 읽으므로 여기서 한 번 더 봐도 공짜다.
    func refreshActiveNow() async {
        let reader = self.reader
        let (uuid, live) = await Task.detached(priority: .userInitiated) {
            (reader.activeOrgUUID(), AltInstance.scanInstances())
        }.value
        setInstances(live)
        await applyActiveOrg(uuid)
        await mirrorBackAll()
    }

    /// 이미 떠 있는 창을 앞으로 꺼낸다.
    ///
    /// 기본 계정은 우리가 띄운 창이 아니라 pid 를 모른다. 우리 pid 를 빼고
    /// 남는 프로세스로 찾는다.
    func focus(_ org: OrgUsage) {
        if org.uuid == activeUUID {
            if !AppFocus.bringPrimaryToFront(excluding: Set(instances.values)) {
                instanceNotice = "\(org.name) 의 기본 창을 못 찾았다"
            }
            return
        }
        guard let slug = AltInstance.slug(org.name), let pid = instances[slug] else { return }
        AppFocus.bringToFront(pid: pid)
    }

    /// 무엇이 지워질지 먼저 센다. 아무것도 건드리지 않는다.
    func previewPurge() {
        let launcher = self.launcher
        let live = running
        Task { [weak self] in
            let plan = await Task.detached { launcher.plan(running: live) }.value
            await MainActor.run {
                if plan.isEmpty {
                    self?.instanceNotice = plan.keptRunning.isEmpty
                        ? "지울 것이 없다"
                        : "떠 있는 창의 것뿐이라 지울 것이 없다. 창을 먼저 닫는다"
                } else {
                    self?.purgePlan = plan
                }
            }
        }
    }

    func cancelPurge() { purgePlan = nil }

    /// 팝오버를 다시 열면 지난 결과를 지운다. 한 번 읽으면 끝인 말이다.
    func clearNotice() {
        instanceNotice = nil
        purgePlan = nil
    }

    /// 확인을 받은 뒤에만 지운다.
    func confirmPurge() {
        guard purgePlan != nil else { return }
        purgePlan = nil
        let launcher = self.launcher
        let live = running
        Task { [weak self] in
            let r = await Task.detached { launcher.removeAll(keeping: live) }.value
            await MainActor.run {
                var say = "\(r.removed)개를 지웠다. \(PurgePlan.size(r.freedBytes)) 확보"
                if r.keptRunning > 0 { say += ". 떠 있는 \(r.keptRunning)개는 남겼다" }
                self?.instanceNotice = say
            }
        }
    }

    private func applyActiveOrg(_ uuid: String?) async {
        guard uuid != activeUUID else { return }
        let first = activeUUID == nil
        activeUUID = uuid

        known = reassignActive(to: uuid, in: known)
        orgs = prefs.apply(to: known)
        rebuildBar()

        // 첫 관측은 전환이 아니다. 시작할 때 도는 읽기와 겹치면 요청만 두 배다
        guard !first else { return }
        await refresh(scheduled: true)
    }

    /// 벽지를 바꾸거나 스페이스를 옮기면 메뉴바 밝기가 바뀐다.
    ///
    /// 시스템 외양은 그대로이므로 외양 알림이 안 온다. 그런 알림이 아예 없어서
    /// 스페이스 전환을 듣고, 그것으로도 안 잡히는 경우를 위해 계정 감시 루프가
    /// 5초마다 밝기를 확인한다. 읽는 값은 프로퍼티 하나라 공짜다.
    private func watchMenuBarBrightness() {
        guard spaceWatch == nil else { return }
        spaceWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.redrawIfBrightnessChanged() }
        }
    }

    /// 메뉴바 밝기가 지난번과 다르면 다시 굽는다.
    private func redrawIfBrightnessChanged() {
        let dark = BarImage.menuBarIsDark
        guard dark != barWasDark else { return }
        barWasDark = dark
        redrawBar()
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

    /// 포커스가 바뀌는 즉시 밑줄이 따라온다. 5초 감시 주기를 기다리면
    /// 창을 바꾸고 한참 지나서야 밑줄이 옮겨간다.
    private func watchFrontApp() {
        guard focusWatch == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication {
            frontPid = front.processIdentifier
            frontExecutable = front.executableURL?.path
        }
        focusWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            let pid = app?.processIdentifier
            let path = app?.executableURL?.path
            Task { @MainActor [weak self] in
                self?.frontAppChanged(pid: pid, executable: path)
            }
        }
    }

    /// 앞 창의 계정. 메뉴바가 이 계정 코드에 밑줄을 긋고, 팝오버가
    /// 이 계정 카드에 배경을 깐다.
    var focusedUUID: String? {
        FocusMark.focusedUUID(frontPid: frontPid, frontExecutable: frontExecutable,
                              instances: instances, orgs: known,
                              activeUUID: activeUUID)
    }

    /// 답이 그대로면 안 굽는다. 앱을 오갈 때마다 구우면 낭비다.
    private func frontAppChanged(pid: Int32?, executable: String?) {
        // 우리 자신이 앞으로 오는 것은 포커스 이동이 아니다. 이걸 반영하면
        // 팝오버를 여는 순간 밑줄과 카드 표시가 사라진다. 사용자가 물은
        // "방금 그 창" 은 팝오버를 열기 직전의 창이다
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        let before = focusedUUID
        frontPid = pid
        frontExecutable = executable
        if focusedUUID != before { redrawBar() }
    }

    /// 인스턴스 목록이 바뀌어도 밑줄의 답이 바뀔 수 있다. 앞 창의
    /// 인스턴스가 죽으면 밑줄이 남아 거짓말을 한다.
    private func setInstances(_ live: [String: Int32]) {
        let before = focusedUUID
        let hadWindows = windowedUUIDs
        instances = live
        // 창이 뜨거나 닫히면 '창이 열려있는 계정만' 의 답이 바뀐다
        if windowedUUIDs != hadWindows { rebuildBar() }
        else if focusedUUID != before { redrawBar() }
    }

    /// 우리가 띄운 별도 창이 붙어 있는 계정.
    private var windowedUUIDs: Set<String> {
        Set(known.filter { org in
            AltInstance.slug(org.name).map { instances[$0] != nil } ?? false
        }.map(\.uuid))
    }

    /// 막대에 올릴 계정을 다시 고르고 다시 그린다.
    private func rebuildBar() {
        barOrgs = prefs.barOrgs(from: known, withWindow: windowedUUIDs)
        redrawBar()
    }

    private func redrawBar() {
        barWasDark = BarImage.menuBarIsDark
        barImage = BarImage.render(orgs: barOrgs, detail: prefs.barDetail,
                                   direction: prefs.gaugeDirection,
                                   resetLabel: prefs.resetLabel,
                                   focusedUUID: focusedUUID)
    }

    /// 남은 시간은 사용량을 다시 안 읽어도 흐른다.
    ///
    /// 막대는 읽기 주기(몇 분)에만 다시 굽는다. 그대로 두면 `9m` 이 한참
    /// 그대로 있다가 갑자기 `4m` 으로 뛴다. 그 모드에서만 1분마다 다시 굽는다.
    private func watchClock() {
        guard clock == nil else { return }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await MainActor.run {
                    guard self?.prefs.resetLabel == .remaining else { return }
                    self?.redrawBar()
                }
            }
        }
    }

    /// 팝오버를 열 때, 새로고침을 누를 때, 그리고 주기 루프가 부를 때.
    ///
    /// **읽기 하나에 요청이 계정 수만큼 나간다.** 팝오버를 여닫을 때마다
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

            // 못 읽은 계정에는 지난번 값을 물려준다. 한 번 실패했다고 화면을
            // 비우면 사용자가 알고 있던 것까지 잃는다
            known = mergeKeepingLastGood(fresh: snapshot.knownOrgs, previous: known)
            if !snapshot.names.isEmpty { cachedNames = snapshot.names }
            orgs = prefs.apply(to: known)
            rebuildBar()
            if !snapshot.throttled { readAt = snapshot.readAt }
            failure = nil
            await notify(at: now)
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

    func setGaugeDirection(_ direction: GaugeDirection) {
        prefs.gaugeDirection = direction
        persist()
    }

    func setResetLabel(_ label: ResetLabel) {
        prefs.resetLabel = label
        persist()
    }

    /// 알림을 켜고 끈다. 켤 때 권한을 한 번 물어본다.
    func setNotify(_ on: Bool) {
        prefs.notify = on
        persist()
        Task { [weak self] in
            guard let self else { return }
            if on {
                // 껐다 켠 사이의 조건은 새 소식으로 받는다
                await MainActor.run { self.notifier.forgetAll() }
                if await MainActor.run(body: { self.notifyPermission != .granted }) {
                    await self.notifier.request()
                }
            }
            await self.notifier.refreshPermission()
            await MainActor.run { self.syncNotifyPermission() }
        }
    }

    func openNotificationSettings() { Notifier.openSystemSettings() }

    private func syncNotifyPermission() {
        notifyPermission = notifier.permission
    }

    /// 지금 참인 알림 조건을 모아 넘긴다.
    ///
    /// **지금 참인 것 전부**를 넘겨야 한다. 사라진 조건의 열쇠를 지우는 일도
    /// 이 목록으로 하기 때문이다.
    private func notify(at now: Date) async {
        let visible = prefs.apply(to: known)
        let alerts = visible.flatMap { org in
            UsageAlerts.build(for: org,
                              others: visible.filter { $0.uuid != org.uuid },
                              now: now)
        }
        guard prefs.notify else {
            // 꺼 둔 동안의 조건은 쌓아 두지 않는다
            notifier.markSeen(alerts)
            notifiedOnce = true
            return
        }
        // 이미 빨강인 상태로 앱을 켠 것은 새 소식이 아니다
        guard notifiedOnce else {
            notifier.markSeen(alerts)
            notifiedOnce = true
            return
        }
        await notifier.deliver(alerts)
    }

    private func persist() {
        try? file?.save(prefs)
        orgs = prefs.apply(to: known)
        rebuildBar()
    }
}
