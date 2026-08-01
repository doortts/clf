import Foundation
import ArgumentParser
import ClflDesktop

/// 데스크톱 앱이 아는 조직들의 사용량. 요청을 보내지 않는다.
/// docs/design/10-desktop-usage.md
struct Desktop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Claude 데스크톱 앱의 조직별 한도",
        subcommands: [Usage.self],
        defaultSubcommand: Usage.self)

    struct Usage: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "5시간, 주간 전체, 주간 모델별 잔여를 조직마다 보여준다")

        @Flag(help: "활성 조직만") var active = false
        @Flag(help: "표 대신 JSON") var json = false

        func run() async throws {
            let reader = DesktopReader()
            guard reader.isInstalled else {
                throw CheckFailed(description: "Claude 데스크톱 앱을 찾지 못했다")
            }
            let snapshot = try await reader.read()
            let orgs = active ? snapshot.orgs.filter(\.isActive) : snapshot.orgs

            if json {
                print(try renderJSON(orgs, unreadable: snapshot.unreadable))
                return
            }
            for org in orgs { render(org) }
            if !active, !snapshot.unreadable.isEmpty {
                print("  아직 못 읽는 조직: " + snapshot.unreadable.joined(separator: ", "))
                print("  앱에서 한 번 열면 토큰이 캐시돼 다음부터 읽힌다")
            }
        }

        private func render(_ org: OrgUsage) {
            let mark = org.isActive ? "*" : " "
            print("\(mark) \(org.name)" + (org.isActive ? "  (지금 앱에서 쓰는 조직)" : ""))
            if let error = org.error {
                print("    \(error)")
                print()
                return
            }
            for kind in LimitKind.allCases {
                guard let limit = org.limits[kind] else { continue }
                let filled = Int((Double(limit.percentUsed) / 100 * 20).rounded())
                let bar = String(repeating: "#", count: filled)
                    + String(repeating: ".", count: 20 - filled)
                // 사용률 0 인 창은 아직 안 열려 리셋 시각이 없다
                let when = limit.resetsAt.map { "\(until($0)) 뒤 리셋" } ?? "창 안 열림"
                let warn = limit.band == .low || limit.band == .empty ? "   주의" : ""
                print("    \(pad(kind.label, to: 10)) [\(bar)] "
                      + "잔여 \(pad(String(limit.percentRemaining), to: 3, right: true))%   "
                      + when + warn)
            }
            print()
        }

        private func renderJSON(_ orgs: [OrgUsage], unreadable: [String]) throws -> String {
            let iso = ISO8601DateFormatter()
            let rows: [[String: Any]] = orgs.map { org in
                var row: [String: Any] = ["uuid": org.uuid, "name": org.name,
                                          "active": org.isActive]
                if let plan = org.plan { row["plan"] = plan }
                if let error = org.error { row["error"] = error }
                var limits: [String: Any] = [:]
                for (kind, limit) in org.limits {
                    var one: [String: Any] = ["percent_used": limit.percentUsed,
                                              "percent_remaining": limit.percentRemaining,
                                              "severity": limit.severity]
                    if let at = limit.resetsAt { one["resets_at"] = iso.string(from: at) }
                    limits[kind.rawValue] = one
                }
                row["limits"] = limits
                return row
            }
            let data = try JSONSerialization.data(
                withJSONObject: ["orgs": rows, "unreadable": unreadable],
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }

        /// 절대 시각보다 남은 시간이 읽기 쉽다.
        private func until(_ date: Date) -> String {
            let minutes = Int(date.timeIntervalSinceNow / 60)
            if minutes < 0 { return "지남" }
            if minutes < 60 { return "\(minutes)분" }
            if minutes < 60 * 24 { return "\(minutes / 60)시간 \(minutes % 60)분" }
            return "\(minutes / 1440)일 \((minutes % 1440) / 60)시간"
        }

        private func pad(_ text: String, to width: Int, right: Bool = false) -> String {
            let gap = String(repeating: " ", count: max(0, width - displayWidth(text)))
            return right ? gap + text : text + gap
        }
    }
}
