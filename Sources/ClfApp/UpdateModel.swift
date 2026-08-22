import AppKit
import Foundation
import SwiftUI
import os
import ClfDesktop

/// 새 버전을 확인하고 제자리에서 갈아 끼운다.
///
/// 상태 하나가 화면이 그릴 것과 다음에 할 수 있는 일을 정한다.
/// docs/design/14-self-update.html, docs/design/17-repo-split.html
///
/// **저장은 이쪽 몫이 아니다.** 마지막 확인 시각과 점을 지운 태그는
/// `DesktopPreferences` 에 있고 그 파일을 쓰는 곳은 `UsageModel` 하나다.
/// 여기서 또 쓰면 같은 파일에 손이 둘이 된다.
@MainActor
final class UpdateModel: ObservableObject {

    enum State: Equatable {
        /// 아직 안 봤다.
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, received: Int64, total: Int64)
        case ready(Release)
        /// 어디서 멈췄는지 한 줄. `error` 로 뭉뚱그리면 할 수 있는 일이 없다.
        case failed(String)
    }

    @Published private(set) var state = State.idle
    /// 확인을 아예 안 하는 이유. 개발 빌드일 때만 값이 있다.
    @Published private(set) var skipped: String?
    /// 지난 설치가 남긴 로그. 있으면 설정에 경로를 보여준다.
    @Published private(set) var staleLog: URL?

    private let paths: UpdatePaths
    private let session: URLSession
    private let bundle: URL
    private let eligibility: UpdateEligibility
    /// 마지막으로 조각을 받은 시각. 무활동 타임아웃이 이걸 본다.
    private var lastProgressAt = Date()
    private var installing = false

    init(paths: UpdatePaths = UpdatePaths(),
         session: URLSession = .shared,
         bundle: URL = Bundle.main.bundleURL,
         version: String = (Bundle.main
            .infoDictionary?["CFBundleShortVersionString"] as? String) ?? "") {
        self.paths = paths
        self.session = session
        self.bundle = bundle
        self.eligibility = UpdateCheck.eligibility(version: version, bundlePath: bundle.path)
        if case .developmentBuild(let why) = eligibility { skipped = why }
    }

    /// 내 버전. 설정의 결과 줄이 이걸 적는다.
    var currentVersion: String {
        if case .eligible(let mine) = eligibility { return mine.description }
        return "개발 빌드"
    }

    /// 지금 보이는 새 버전의 태그. 톱니의 점을 지울 때 이 값을 저장한다.
    var newTag: String? {
        switch state {
        case .available(let r), .downloading(let r, _, _), .ready(let r): return r.tag
        default: return nil
        }
    }

    /// 사용자가 아직 안 본 새 버전이 있나. 톱니에 점을 올릴지 정한다.
    func hasNews(seen: String?) -> Bool {
        guard let newTag else { return false }
        return newTag != seen
    }

    /// 릴리즈 페이지에서 직접 받으라고 안내할 때 쓸 태그.
    private var linkTag: String { newTag ?? "" }

    /// 지금 눌러도 되는지. 확인 중이거나 설치 중이면 아이콘을 흐리게 한다.
    var busy: Bool {
        if installing { return true }
        switch state {
        case .checking, .downloading, .ready: return true
        default: return false
        }
    }

    /// 제자리 교체가 가능한 상태인지.
    ///
    /// 관리자가 `/Applications` 에 넣어 둔 번들은 사용자 권한으로 못 바꾼다.
    /// 그때는 **직접 받기** 만 보여준다. 권한을 올려 달라고 묻지 않는다.
    var canInstall: Bool {
        guard case .available(let release) = state else { return false }
        return release.dmg != nil && UpdateInstaller.canReplace(bundle: bundle)
    }

    /// 자동 설치가 막힌 이유. 카드 아래 한 줄로 붙는다.
    var installBlockedReason: String? {
        guard case .available(let release) = state else { return nil }
        if release.dmg == nil { return "이 릴리즈에는 받을 DMG 가 없습니다" }
        if !UpdateInstaller.canReplace(bundle: bundle) {
            return "이 번들이 있는 폴더에 쓸 수 없습니다. 직접 받아 바꿔 넣어야 합니다"
        }
        return nil
    }

    // MARK: 확인

    /// 켤 때와 하루 한 번, 그리고 팝오버를 열 때. 시각 판단의 기준값은 부르는
    /// 쪽이 넘긴다.
    ///
    /// 간격도 부르는 쪽이 정한다. 주기 루프는 하루, 팝오버는 한 시간이다.
    /// 확인했으면 그 시각을 돌려준다. 부르는 쪽이 그것을 설정에 적는다.
    @discardableResult
    func checkIfDue(last: Date?, now: Date = Date(),
                    interval: TimeInterval = UpdateCheck.checkInterval) async -> Date? {
        guard case .eligible = eligibility else { return nil }
        guard UpdateCheck.shouldCheck(last: last, now: now, interval: interval) else {
            return nil
        }
        await check()
        return now
    }

    /// 손으로 누르는 확인. 24시간 규칙을 무시한다.
    @discardableResult
    func checkNow(now: Date = Date()) async -> Date? {
        guard case .eligible = eligibility else { return nil }
        await check()
        return now
    }

    private func check() async {
        guard !busy else { return }
        guard case .eligible(let mine) = eligibility else { return }
        state = .checking

        var request = URLRequest(url: ProjectLinks.latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // 익명이라 시간당 60회다. 안 바뀌었으면 한도를 깎지 않는다
        if let tag = try? String(contentsOf: paths.etag, encoding: .utf8),
           !tag.isEmpty {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            switch UpdateCheck.classify(status: http?.statusCode ?? 0, body: data) {
            case .release(let release):
                remember(release: data, etag: http?.value(forHTTPHeaderField: "ETag"))
                decide(release, mine: mine)
            case .notModified:
                // 손에 값이 있어야 한다. 캐시한 본문을 다시 읽는다
                if let cached = try? Data(contentsOf: paths.latestJSON),
                   let release = UpdateCheck.decode(cached) {
                    decide(release, mine: mine)
                } else {
                    // 짝이 깨졌다. ETag 를 버리고 다음 확인에 다시 받는다
                    try? FileManager.default.removeItem(at: paths.etag)
                    state = .upToDate
                }
            case .none:
                // 릴리즈가 하나도 없다. 오류가 아니다
                state = .upToDate
            case .failed(let why):
                state = .failed(why)
            }
        } catch {
            // **실패는 조용히 지나간다.** 사용량 읽기가 실패하면 앱이 쓸 데가
            // 없어지지만 업데이트 확인이 실패하는 것은 다음에 다시 보면 되는
            // 일이다. 팝오버 머리에 빨간 줄을 띄우지 않고 설정에만 적는다
            state = .failed("릴리즈를 읽지 못했습니다")
        }
    }

    private func decide(_ release: Release, mine: ReleaseVersion) {
        guard let theirs = release.version else {
            // 태그가 우리 꼴이 아니다. 견줄 수가 없으니 최신으로 둔다
            state = .upToDate
            return
        }
        state = theirs > mine ? .available(release) : .upToDate
    }

    private func remember(release data: Data, etag: String?) {
        try? FileManager.default.createDirectory(at: paths.cacheRoot,
                                                 withIntermediateDirectories: true)
        try? data.write(to: paths.latestJSON)
        guard let etag, !etag.isEmpty else {
            try? FileManager.default.removeItem(at: paths.etag)
            return
        }
        try? etag.write(to: paths.etag, atomically: true, encoding: .utf8)
    }

    // MARK: 설치

    /// 받아서 확인하고 갈아 끼운다. 사람이 단추를 눌러야 시작한다.
    func install() async {
        guard case .available(let release) = state, canInstall,
              let source = release.dmg, !installing
        else { return }
        installing = true
        defer { installing = false }

        let tag = release.tag
        let staging = paths.staging(tag: tag)
        let dmg = paths.dmg(tag: tag)
        let mount = paths.mountPoint(tag: tag)
        let staged = paths.stagedApp(tag: tag)

        do {
            try FileManager.default.createDirectory(at: staging,
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.logRoot,
                                                    withIntermediateDirectories: true)
        } catch {
            state = .failed("캐시 폴더를 만들지 못했습니다")
            return
        }

        state = .downloading(release, received: 0, total: release.bytes ?? 0)
        guard await download(source, to: dmg, release: release) else { return }

        // 붙였다 곧바로 뗀다. 안 떼면 Finder 사이드바에 볼륨이 쌓인다
        try? FileManager.default.removeItem(at: mount)
        let attach = await Self.shell("/usr/bin/hdiutil",
                                      ["attach", "-nobrowse", "-readonly",
                                       "-mountpoint", mount.path, dmg.path],
                                      timeout: 60)
        guard attach.code == 0 else {
            state = .failed("DMG 마운트 실패. 받은 파일이 온전하지 않습니다")
            return
        }

        try? FileManager.default.removeItem(at: staged)
        let inside = mount.appendingPathComponent("clf.app")
        var copied = FileManager.default.fileExists(atPath: inside.path)
        if copied {
            let copy = await Self.shell("/usr/bin/ditto", [inside.path, staged.path],
                                        timeout: 60)
            copied = copy.code == 0
        }
        // 성공이든 실패든 뗀다. 붙은 채로 두면 다음 시도의 마운트가 막힌다
        _ = await Self.shell("/usr/bin/hdiutil", ["detach", "-quiet", mount.path],
                             timeout: 60)
        try? FileManager.default.removeItem(at: mount)

        guard copied else {
            state = .failed("DMG 안에서 clf.app 을 꺼내지 못했습니다")
            return
        }

        // **관문.** helper 에게 번들을 덮어쓸 권한을 주기 전 마지막 검사다
        let verdict = await Self.shell("/usr/sbin/spctl", ["-a", "-vv", staged.path],
                                       timeout: 60)
        guard UpdateInstaller.gatekeeperAccepted(verdict.out) else {
            state = .failed("공증 확인 실패. 이 번들로 바꾸지 않습니다")
            return
        }

        guard launchHelper(tag: tag, staged: staged, staging: staging) else {
            state = .failed("설치 스크립트를 띄우지 못했습니다")
            return
        }

        state = .ready(release)
        // 여기까지 왔으면 사용자가 이미 한 번 눌렀다. 다시 물어볼 것이 없다
        try? await Task.sleep(for: .seconds(2))
        NSApplication.shared.terminate(nil)
    }

    /// DMG 를 받는다. 진행률과 무활동을 같이 본다.
    ///
    /// 통로에 넘길 것을 **초기화 때 다 넘긴다.** 델리게이트가 `Sendable` 이라
    /// 저장 칸을 나중에 채울 수 없다. 자세한 사정은 `DownloadRelay` 에 적었다.
    private func download(_ from: URL, to target: URL, release: Release) async -> Bool {
        lastProgressAt = Date()
        let expected = release.bytes ?? 0
        // 감시자는 부르는 쪽이 쥔다. 통로에 맡기면 그 저장 칸이 가변이 되어야
        // 한다. 여기 두면 기다림이 끝나는 자리에서 같이 접힌다
        var watchdog: Task<Void, Never>?
        defer { watchdog?.cancel() }

        do {
            return try await withCheckedThrowingContinuation { continuation in
                let relay = DownloadRelay(
                    target: target,
                    onProgress: { [weak self] received, total in
                        Task { @MainActor in
                            guard let self else { return }
                            self.lastProgressAt = Date()
                            guard case .downloading = self.state else { return }
                            self.state = .downloading(release, received: received,
                                                      total: total > 0 ? total : expected)
                        }
                    },
                    onFinish: { continuation.resume(with: $0) })

                let downloader = URLSession(configuration: .ephemeral, delegate: relay,
                                            delegateQueue: nil)
                let task = downloader.downloadTask(with: from)
                // **요청 전체 타임아웃과 다르다.** 사내망이나 프록시가 연결은
                // 열어 둔 채 조각을 안 보내면 전체 타임아웃만으로는 영영
                // 기다리고, 화면에는 멈춘 막대가 남는다
                watchdog = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        guard let self else { return }
                        let idle = await MainActor.run {
                            Date().timeIntervalSince(self.lastProgressAt)
                        }
                        if idle > 30 { task.cancel(); return }
                    }
                }
                task.resume()
                // 새 태스크만 막는다. 지금 것은 끝까지 가고, 끝나면 세션이
                // 델리게이트 참조를 놓는다. 안 부르면 세션과 델리게이트가
                // 서로를 잡고 안 죽는다
                downloader.finishTasksAndInvalidate()
            }
        } catch {
            state = .failed("내려받기가 멈췄습니다. 다시 시도해 보세요")
            return false
        }
    }

    /// helper 를 띄우고 로그 경로를 먼저 남긴다.
    private func launchHelper(tag: String, staged: URL, staging: URL) -> Bool {
        let log = paths.log(tag: tag)
        let script = UpdateInstaller.helperScript(
            bundle: bundle, staged: staged, cache: staging, log: log,
            pid: ProcessInfo.processInfo.processIdentifier)
        let helper = paths.helper(tag: tag)
        do {
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: helper.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [helper.path]
            // 기다리지 않는다. 우리가 죽어야 저쪽이 일을 시작한다
            try process.run()
            staleLog = log
            return true
        } catch {
            return false
        }
    }

    // MARK: 앞선 시도의 흔적

    /// 지난 설치가 끝났는지 본다. 성공하면 helper 가 캐시를 지우므로 남은
    /// 폴더는 끝나지 않았다는 뜻이다.
    ///
    /// yonagit 에서 가져온 것 중 가장 값이 나가는 한 줄이다. helper 는 앱이
    /// 죽은 뒤에 돌아서, 이 흔적이 없으면 사용자에게는 앱이 다시 안 뜬다는
    /// 사실만 남는다.
    func findStaleAttempt() {
        let fm = FileManager.default
        guard let left = try? fm.contentsOfDirectory(at: paths.cacheRoot,
                                                     includingPropertiesForKeys: nil)
        else { return }
        let tags = left.filter { $0.hasDirectoryPath }.map(\.lastPathComponent)
        guard let tag = tags.sorted().last else { return }
        let log = paths.log(tag: tag)
        staleLog = fm.fileExists(atPath: log.path) ? log : nil
    }

    // MARK: 바깥으로 나가는 문

    /// 사람용 링크는 전부 사내 GHE 다. docs/design/17-repo-split.html 3절
    func openReleaseNotes() { NSWorkspace.shared.open(ProjectLinks.releasePage(tag: linkTag)) }
    func openReleases() { NSWorkspace.shared.open(ProjectLinks.releases) }
    func openIssue() { NSWorkspace.shared.open(ProjectLinks.newIssue) }

    /// 이미 손에 있는 DMG 가 막힌 사람에게 가장 짧은 탈출구다.
    func revealDownload() {
        guard let tag = newTag else { return }
        let dmg = paths.dmg(tag: tag)
        guard FileManager.default.fileExists(atPath: dmg.path) else {
            NSWorkspace.shared.open(ProjectLinks.releasePage(tag: tag))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([dmg])
    }

    func openStaleLog() {
        guard let staleLog else { return }
        NSWorkspace.shared.activateFileViewerSelecting([staleLog])
    }

    /// 막힌 그 단계부터 다시 간다. 확인 아이콘과 하는 일이 다르다.
    func retry() async {
        guard case .failed = state else { return }
        if let cached = try? Data(contentsOf: paths.latestJSON),
           let release = UpdateCheck.decode(cached),
           case .eligible(let mine) = eligibility {
            decide(release, mine: mine)
            if case .available = state { await install() }
            return
        }
        await checkNow()
    }

    // MARK: 프로세스

    /// 하나 돌리고 (종료코드, 출력) 을 받는다.
    ///
    /// 시간이 넘으면 죽인다. `hdiutil` 이 걸리면 사용자는 이유를 알 길이 없다.
    private nonisolated static func shell(_ path: String, _ args: [String],
                                          timeout: TimeInterval) async
        -> (code: Int32, out: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, "\(error)"))
                    return
                }
                let killer = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                // 파이프를 먼저 비운다. 버퍼가 차면 자식이 멈춰서 교착이 된다
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                                 as: UTF8.self)
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: (process.terminationStatus, out))
            }
        }
    }
}

/// 내려받기의 진행률과 완료를 넘겨주는 통로.
///
/// `didFinishDownloadingTo` 가 준 파일은 **그 함수가 돌아가는 사이에만** 있다.
/// 옮기는 것을 콜백 안에서 끝내야 한다.
///
/// **저장 칸이 전부 불변이어야 한다.** SDK 가 `NSURLSessionDelegate` 를
/// `NS_SWIFT_SENDABLE` 로 표시해 두었으므로 이 클래스는 `Sendable` 이 되고,
/// 가변 칸을 두면 컴파일러가 경고한다. 경고로만 끝나는 일도 아니다. 우리는
/// 메인 액터에서 값을 넣는데 델리게이트 호출은 세션이 만든 백그라운드 직렬
/// 큐에서 오므로 그 사이에 순서를 보장하는 것이 아무것도 없다. 그래서 이어질
/// 곳을 초기화 때 받고, 감시자는 부르는 쪽이 쥔다.
private final class DownloadRelay: NSObject, URLSessionDownloadDelegate {
    private let target: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let onFinish: @Sendable (Result<Bool, Error>) -> Void
    /// 이어 주기를 한 번으로 막는다.
    ///
    /// **확인된 연속체를 두 번 재개하면 프로세스가 죽는다.** 성공 콜백과 실패
    /// 콜백이 겹쳐 오지 않는다는 것은 URLSession 의 약속이지만, 어긋났을 때 치를
    /// 값이 하필 업데이트 도중의 크래시라 약속에 기대지 않는다.
    /// `clfctl` 의 `OnceFlag` 와 같은 일을 하는데, 이 자리는 검사받는 `Sendable`
    /// 이라 `@unchecked` 를 새로 들이지 않는 쪽을 쓴다.
    private let settled = OSAllocatedUnfairLock(initialState: false)

    init(target: URL,
         onProgress: @escaping @Sendable (Int64, Int64) -> Void,
         onFinish: @escaping @Sendable (Result<Bool, Error>) -> Void) {
        self.target = target
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    private func settle(_ result: Result<Bool, Error>) {
        let first = settled.withLock { done -> Bool in
            guard !done else { return false }
            done = true
            return true
        }
        guard first else { return }
        onFinish(result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            settle(.failure(URLError(.badServerResponse)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            settle(.success(true))
        } catch {
            settle(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }   // 성공은 위에서 이미 알렸다
        settle(.failure(error))
    }
}
