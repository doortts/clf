import Foundation
import ArgumentParser
import ClfCore
import ClfStore

struct Runtime: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "조직별 런타임 상태",
        subcommands: [Show.self, Clear.self, Simulate.self],
        defaultSubcommand: Show.self)

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "runtime.json 을 표로")
        @OptionGroup var paths: Paths
        @Option(help: "여유를 계산할 모델") var model: String = "claude-opus-4-5"

        func run() async throws {
            let doc = try await paths.accountsFile().load()
            let runtime = await (try paths.runtimeFile()).load()
            let now = Date()

            let rows = doc.priority.map { id -> [String] in
                let rt = runtime[id] ?? AccountRuntime()
                let state = availability(rt, for: model, now: now, activeID: nil, id: id)
                return [id, describe(state),
                        percent(rt.rateLimit?.fiveHour.map { 1 - $0.usedRatio }),
                        percent(rt.rateLimit?.sevenDayAll.map { 1 - $0.usedRatio }),
                        percent(rt.rateLimit?.modelWeekly[model].map { 1 - $0.usedRatio }),
                        percent(bindingHeadroom(rt.rateLimit, for: model, now: now,
                                                requireKnownReset: false)),
                        stamp(rt.lastUsedAt)]
            }
            print(renderTable(["id", "상태", "5h", "7d", "모델7d", "구속여유", "최근사용"], rows))
            print()
            print("  잔여 기준이다. 구속여유는 셋 중 가장 좁은 창이다")
        }
    }

    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "쿨다운과 무효 표시를 지운다. 사용량 읽기는 남긴다")
        @OptionGroup var paths: Paths
        @Argument(help: "생략하면 전부") var id: String?

        func run() async throws {
            let file = try paths.runtimeFile()
            var runtime = await file.load()
            for key in runtime.keys where id == nil || key == id {
                runtime[key]?.accountCooldownUntil = nil
                runtime[key]?.modelCooldowns = [:]
                runtime[key]?.invalidatedAt = nil
            }
            await file.schedule(runtime)
            try await file.flush()
            print("  지웠다 \(id ?? "전부")")
        }
    }

    /// 429 를 실제로 맞지 않고 스왑 경로를 밟아 보기 위한 것이다.
    struct Simulate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "쿨다운이나 무효 상태를 손으로 만든다",
            discussion: """
            한도에 실제로 걸릴 때까지 기다리지 않고 선택기 동작을 확인한다.

              clfctl runtime simulate team1 --rate-limit 300
              clfctl runtime simulate team1 --session-limit 1800
              clfctl runtime simulate team1 --invalid
              clfctl runtime simulate team1 --headroom 0.03
            """)
        @OptionGroup var paths: Paths

        @Argument var id: String
        @Option(help: "이 모델을 N초간 쿨다운") var rateLimit: Int?
        @Option(help: "계정 전체를 N초간 쿨다운") var sessionLimit: Int?
        @Flag(help: "자격증명 무효로 표시") var invalid = false
        @Option(help: "5시간 창 잔여 비율을 이 값으로 심는다") var headroom: Double?
        @Option(help: "쿨다운 대상 모델") var model: String = "claude-opus-4-5"

        func run() async throws {
            let doc = try await paths.accountsFile().load()
            guard doc.accounts[id] != nil else {
                throw CheckFailed(description: "\(id) 는 등록돼 있지 않다")
            }
            let file = try paths.runtimeFile()
            var runtime = await file.load()
            var rt = runtime[id] ?? AccountRuntime()
            let now = Date()

            if let seconds = rateLimit {
                rt.modelCooldowns[model] = now.addingTimeInterval(TimeInterval(seconds))
            }
            if let seconds = sessionLimit {
                rt.accountCooldownUntil = now.addingTimeInterval(TimeInterval(seconds))
            }
            if invalid { rt.invalidatedAt = now }
            if let remaining = headroom {
                var snapshot = rt.rateLimit
                    ?? RateLimitSnapshot(observedAt: now, source: .headers)
                snapshot.fiveHour = Window(usedRatio: 1 - remaining,
                                           resetsAt: now.addingTimeInterval(3600))
                snapshot.observedAt = now
                rt.rateLimit = snapshot
            }

            runtime[id] = rt
            await file.schedule(runtime)
            try await file.flush()
            print("  \(id) 상태를 바꿨다. clfctl select 로 확인한다")
        }
    }
}

func describe(_ state: Availability) -> String {
    switch state {
    case .active:                       return "활성"
    case .ready:                        return "준비"
    case .invalid(let since):           return "무효 \(stamp(since))"
    case .cooling(let until, .account): return "계정쿨다운 \(stamp(until))"
    case .cooling(let until, .model):   return "모델쿨다운 \(stamp(until))"
    }
}
