import Foundation
import ArgumentParser
import ClflCore
import ClflStore
import ClflProxy

/// 사다리 8칸. 프록시를 앱 없이 띄운다.
///
/// 통과 기준은 이 명령이 뜨는 것이 아니라 **Claude Code 데스크톱 앱으로 대화가
/// 성립하는 것**이다. docs/design/08-verification.md 4절
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "프록시를 띄운다",
        discussion: """
        8단계는 스왑 없이 조직 하나로만 통과시킨다.

          clflctl serve --single naver_team_40
          clflctl serve --single naver_team_40 --install

        --install 은 뜨는 데 성공한 뒤에 settings.json 을 고치고, 끝날 때 되돌린다.
        포트 바인딩에 실패하면 주입하지 않는다. 앱이 없는데 설정만 남으면
        Claude Code 가 통째로 고장 난 것처럼 보인다.
        """)

    @OptionGroup var paths: Paths

    @Option(help: "이 조직 하나로만 통과시킨다") var single: String
    @Option(help: "바인딩할 포트. 0 이면 빈 포트를 고른다") var port: UInt16 = 51710
    @Flag(help: "뜬 뒤 settings.json 에 주입하고 끝날 때 되돌린다") var install = false
    @Flag(name: .customLong("no-tool-search"), help: "MCP 도구 검색을 켜지 않는다")
    var noToolSearch = false

    func run() async throws {
        let doc = try await paths.accountsFile().load()
        guard let account = doc.accounts[single] else {
            throw CheckFailed(description: "\(single) 는 등록돼 있지 않다. clflctl accounts list")
        }
        let credentials = paths.credentials
        guard credentials.hasCredential(for: single) else {
            throw CheckFailed(description: "\(single) 의 자격증명이 Keychain 에 없다")
        }

        let executor = HTTPUpstreamExecutor()
        let sink = JSONLSink(directory: try paths.data)
        let handler = SingleAccountHandler(
            account: account,
            tokens: StoredTokenProvider(store: credentials),
            executor: executor, events: sink)

        let server = ProxyServer(handler: handler)
        let bound: UInt16
        do {
            bound = try await server.start(port: port)
        } catch {
            await executor.shutdown()
            throw CheckFailed(description: """
            포트 \(port) 에 바인딩하지 못했다: \(error)
            이미 다른 인스턴스가 떠 있는지 확인하거나 --port 0 으로 빈 포트를 고른다.
            """)
        }

        // 바인딩 성공 뒤에만 주입한다. 순서를 뒤집으면 앱 없이 설정만 남는다
        let settings = try paths.settings()
        if install {
            do {
                try settings.install(baseURL: URL(string: "http://127.0.0.1:\(bound)")!,
                                     enableToolSearch: !noToolSearch, force: true)
            } catch {
                await server.shutdown()
                await executor.shutdown()
                throw CheckFailed(description: "settings.json 을 고치지 못했다: \(error)")
            }
        }

        print("  조직    \(single) (\(account.plan.rawValue))")
        // 0 은 빈 포트를 골라 달라는 뜻이므로 "대신" 이라고 할 것이 없다
        print("  포트    \(bound)"
              + (port == 0 || bound == port ? "" : " (요청한 \(port) 이 막혀 있다)"))
        print("  주입    " + (install ? "했다. 끝낼 때 되돌린다" : "안 했다. 직접 설정한다"))
        print("  로그    \(try paths.data.appendingPathComponent("usage.jsonl").path)")
        print()
        if !install {
            print("  Claude Code 가 이 프록시를 보게 하려면 다른 터미널에서")
            print("    clflctl settings install --port \(bound)")
            print()
        }
        print("  Ctrl-C 로 끝낸다")

        await waitForInterrupt()

        print()
        print("  정리하는 중")
        if install { try? settings.uninstall() }
        await server.shutdown()
        await executor.shutdown()
        sink.drain()
        print("  끝났다" + (install ? ". settings.json 을 되돌렸다" : ""))
    }

    /// SIGINT 를 기다린다.
    ///
    /// 기본 처리기를 끄고 소스로 받는다. 그래야 되돌리기를 마치고 나갈 수 있다.
    /// 그냥 죽으면 settings.json 에 우리 값이 남아 Claude Code 가 고장 난 것처럼 보인다.
    private func waitForInterrupt() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let once = OnceFlag()
            // 핸들러가 소스를 잡아 순환 참조를 만든다. 그래야 소스가 살아 있고,
            // cancel 이 핸들러를 놓으면서 순환이 풀린다
            source.setEventHandler { [source] in
                guard once.claim() else { return }
                source.cancel()
                continuation.resume()
            }
            signal(SIGINT, SIG_IGN)
            source.resume()
        }
    }
}

/// 이벤트 처리기가 두 번 불려도 continuation 은 한 번만 재개해야 한다.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
