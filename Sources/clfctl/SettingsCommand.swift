import Foundation
import ArgumentParser
import ClfStore

struct Settings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "~/.claude/settings.json 의 env 블록",
        subcommands: [Show.self, Install.self, Uninstall.self],
        defaultSubcommand: Show.self)

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "현재 주입 상태")
        @OptionGroup var paths: Paths

        func run() async throws {
            let file = try paths.claude.appendingPathComponent("settings.json")
            print("  파일    \(file.path)")
            guard let data = FileManager.default.contents(atPath: file.path) else {
                print("  상태    파일 없음")
                return
            }
            let env = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["env"]
                as? [String: Any] ?? [:]
            print("  상태    " + (try paths.settings().readManagedBaseURL()
                                    .map { "주입됨 -> \($0.absoluteString)" } ?? "주입 안 됨"))
            print()
            print(renderTable(["env 키", "값"],
                              env.keys.sorted().map { [$0, "\(env[$0]!)"] }))
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "ANTHROPIC_BASE_URL 과 ENABLE_TOOL_SEARCH 를 넣는다")
        @OptionGroup var paths: Paths

        @Option(help: "프록시 포트") var port: UInt16 = 51710
        @Flag(help: "남의 값이 이미 있어도 덮어쓴다") var force = false
        @Flag(name: .customLong("no-tool-search"),
              help: "MCP 도구 검색을 켜지 않는다. 문제 해결용이며 기본은 켬이다")
        var noToolSearch = false

        func run() async throws {
            let url = URL(string: "http://127.0.0.1:\(port)")!
            do {
                try paths.settings().install(baseURL: url,
                                             enableToolSearch: !noToolSearch, force: force)
            } catch StoreError.settingsConflict(let key, let existing) {
                throw CheckFailed(description: """
                \(key) 에 이미 다른 값이 있다: \(existing)
                덮어쓰려면 --force 를 준다. 원래 값은 settings.json.clf.bak 에 남는다.
                """)
            }
            print("  주입했다 -> \(url.absoluteString)")
            print("  도구 검색 \(noToolSearch ? "끔" : "켬")")
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "우리 키만 제거한다")
        @OptionGroup var paths: Paths

        func run() async throws {
            try paths.settings().uninstall()
            print("  제거했다. Claude Code 는 직접 호출로 돌아간다")
        }
    }
}
