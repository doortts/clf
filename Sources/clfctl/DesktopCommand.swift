import Foundation
import ArgumentParser
import ClfDesktop

/// 데스크톱 앱이 아는 계정들의 사용량. 요청을 보내지 않는다.
/// docs/design/10-desktop-usage.md
struct Desktop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Claude 데스크톱 앱의 계정별 한도",
        subcommands: [Usage.self, Orgs.self, Show.self, Hide.self, Order.self, Bar.self],
        defaultSubcommand: Usage.self)

    struct Usage: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "5시간, 주간 전체, 주간 Fable 잔여를 계정마다 보여준다")

        @Flag(help: "활성 계정만") var active = false
        @Flag(help: "표 대신 JSON") var json = false

        func run() async throws {
            let reader = DesktopReader()
            guard reader.isInstalled else {
                throw CheckFailed(description: "Claude 데스크톱 앱을 찾지 못했다")
            }
            let snapshot = try await reader.read()
            // 설정에서 끈 계정은 빼고 사용자가 정한 순서로
            let prefs = try DesktopPreferencesFile().load()
            var orgs = prefs.apply(to: snapshot.orgs)
            if active { orgs = orgs.filter(\.isActive) }

            if json {
                print(try renderJSON(orgs, unreadable: snapshot.unreadable))
                return
            }
            for org in orgs { render(org) }
            if !active, !snapshot.unreadable.isEmpty {
                print("  아직 못 읽는 계정: " + snapshot.unreadable.joined(separator: ", "))
                print("  앱에서 한 번 열면 토큰이 캐시돼 다음부터 읽힌다")
            }
        }

        private func render(_ org: OrgUsage) {
            let mark = org.isActive ? "*" : " "
            print("\(mark) \(org.name)" + (org.isActive ? "  (지금 앱에서 쓰는 계정)" : ""))
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
            // Enterprise 는 시간 창이 없다. 그 줄도 그리지 않으면 이름만 남는다
            if let spend = org.spend, org.limits.isEmpty {
                let filled = Int((Double(spend.percentUsed) / 100 * 20).rounded())
                let bar = String(repeating: "#", count: filled)
                    + String(repeating: ".", count: 20 - filled)
                print("    \(pad("월 예산", to: 10)) [\(bar)] "
                      + "잔여 \(pad(String(spend.percentRemaining), to: 3, right: true))%   "
                      + "\(spend.usedText) / \(spend.limitText) 사용")
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

// MARK: 설정

extension Desktop {
    /// 설정 화면이 보는 목록. 숨긴 것도 함께 보여야 다시 켤 수 있다.
    struct Orgs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "아는 계정 전부와 표시 여부")

        func run() async throws {
            let snapshot = try await DesktopReader().read()
            let prefs = try DesktopPreferencesFile().load()
            let known = snapshot.knownOrgs
            let ordered = prefs.apply(to: known).map(\.uuid)

            let rows = known.map { org -> [String] in
                let shown = !prefs.isHidden(org.uuid)
                let position = ordered.firstIndex(of: org.uuid).map { String($0 + 1) } ?? "-"
                return [shown ? "표시" : "숨김", position, org.name,
                        org.plan ?? "-", org.isActive ? "활성" : "",
                        org.error == nil ? "읽힘" : "못 읽음", org.uuid]
            }
            print(renderTable(["", "순서", "이름", "플랜", "", "사용량", "uuid"], rows))
            print()
            let bar = prefs.barOrgs(from: known).map(\.name).joined(separator: ", ")
            print("  막대: \(prefs.barContent.label) (\(bar.isEmpty ? "비어 있음" : bar))")
            print("  팝오버에는 보이는 계정이 전부 나온다")
            print()
            print("  clfctl desktop hide <이름|uuid>    목록에서 뺀다")
            print("  clfctl desktop show <이름|uuid>    다시 넣는다")
            print("  clfctl desktop order <이름>...     순서를 정한다")
            print("  clfctl desktop bar <active|all>   막대에 그릴 범위")
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "계정을 다시 보이게 한다")
        @Argument var target: String
        func run() async throws { try await setVisibility(target, hidden: false) }
    }

    struct Hide: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "계정을 메뉴바에서 뺀다. 설정 목록에는 남는다")
        @Argument var target: String
        func run() async throws { try await setVisibility(target, hidden: true) }
    }

    struct Order: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "표시 순서를 정한다. 빠뜨린 계정은 뒤에 붙는다")
        @Argument(help: "보고 싶은 순서대로") var targets: [String]

        func run() async throws {
            let known = try await DesktopReader().read().knownOrgs
            let file = try DesktopPreferencesFile()
            var prefs = file.load()
            prefs.order = try targets.map { try resolve($0, in: known).uuid }
            try file.save(prefs)

            let shown = prefs.apply(to: known).map(\.name)
            print("  " + shown.joined(separator: " > "))
        }
    }

    /// 창이 열린 계정만 그릴지 설정에서 고른 계정을 그릴지.
    struct Bar: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "메뉴바 막대에 그릴 범위를 정한다")
        @Argument(help: "window 또는 chosen") var mode: String

        func run() async throws {
            let content: BarContent
            switch mode.lowercased() {
            // 옛 이름도 받는다. 손에 익은 것을 갑자기 막을 이유가 없다
            case "window", "windowed", "active", "active_only": content = .windowed
            case "chosen", "all", "all_visible":                content = .chosen
            default:
                throw CheckFailed(description: "'\(mode)' 를 모른다. window 또는 chosen")
            }
            let file = try DesktopPreferencesFile()
            var prefs = file.load()
            prefs.barContent = content
            try file.save(prefs)

            let known = try await DesktopReader().read().knownOrgs
            // 메뉴바와 같은 답을 내야 한다. 창이 떠 있는지도 같이 본다
            let running = AltInstance.scanInstances()
            let windowed = Set(known.filter { org in
                AltInstance.slug(org.name).map { running[$0] != nil } ?? false
            }.map(\.uuid))
            let bar = prefs.barOrgs(from: known, withWindow: windowed)
                .map(\.name).joined(separator: ", ")
            print("  막대: \(content.label) (\(bar.isEmpty ? "비어 있음" : bar))")
        }
    }
}

/// 이름으로도 uuid 로도 지정할 수 있게 한다. uuid 를 외울 이유가 없다.
private func resolve(_ target: String, in orgs: [OrgUsage]) throws -> OrgUsage {
    let hits = orgs.filter {
        $0.uuid == target || $0.name.lowercased() == target.lowercased()
    }
    guard hits.count == 1 else {
        throw CheckFailed(description:
            "'\(target)' 에 맞는 계정이 \(hits.count)개다. clfctl desktop orgs 로 확인한다")
    }
    return hits[0]
}

private func setVisibility(_ target: String, hidden: Bool) async throws {
    let known = try await DesktopReader().read().knownOrgs
    let org = try resolve(target, in: known)
    let file = try DesktopPreferencesFile()
    var prefs = file.load()
    prefs.setHidden(org.uuid, hidden)
    try file.save(prefs)

    let remaining = prefs.apply(to: known)
    print("  \(org.name) \(hidden ? "숨김" : "표시")")
    print("  지금 보이는 계정: "
          + (remaining.isEmpty ? "없음" : remaining.map(\.name).joined(separator: ", ")))
}
