import Foundation
import ArgumentParser
import ClfCore
import ClfStore

/// 지금 이 순간 요청이 들어오면 어디로 가는지, 그리고 나머지는 왜 안 갔는지.
///
/// 실행 중 컨트롤 플레인이 내보내는 표와 같은 레코드다. 오프라인에서 먼저 이걸로
/// 판정을 확인하고, 프록시가 뜬 뒤에는 같은 표를 실시간으로 본다.
/// docs/design/08-verification.md 3절
struct Select: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "현재 상태로 선택 판정을 돌리고 이유를 보여준다")

    @OptionGroup var paths: Paths

    @Option(help: "요청 모델") var model: String = "claude-opus-4-5"
    @Flag(help: "대화 시작으로 본다. 선제 강등이 켜진다") var start = false
    @Option(help: "이미 시도한 조직. 쉼표로 구분") var tried: String?
    @Option(help: "직전 활성 조직") var active: String?
    @Flag(help: "표 대신 JSON") var json = false

    func run() async throws {
        let doc = try await paths.accountsFile().load()
        guard !doc.accounts.isEmpty else {
            throw CheckFailed(description: "등록된 조직이 없다. clfctl accounts add <id>")
        }
        let runtime = await (try paths.runtimeFile()).load()
        let triedSet = Set((tried ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })

        let explanation = explain(SelectionInput(
            priority: doc.priority, accounts: doc.accounts, runtime: runtime,
            model: model, now: Date(), tried: triedSet,
            activeID: active, isConversationStart: start))

        if json {
            print(try renderJSON(explanation))
            return
        }

        print(renderTable(["순위", "id", "판정", "여유", "이유"],
                          explanation.verdicts.enumerated().map { index, v in
                              ["\(index + 1)", v.id, mark(v.disposition),
                               percent(v.headroom), v.reason]
                          }))
        print()
        switch explanation.result {
        case .selected(let s):
            print("  결과    \(s.accountID) (\(s.plan.rawValue))"
                  + (s.isCrossPlan ? "  플랜이 바뀐다" : ""))
        case .wait(let until):
            print("  결과    대기. \(stamp(until)) 에 가장 이른 조직이 풀린다")
        case .exhausted(let unblockable):
            print("  결과    풀 소진")
            if !unblockable.isEmpty {
                print("  자동 전환을 켜면 바로 쓸 수 있다: \(unblockable.joined(separator: ", "))")
            }
        }
    }

    private func mark(_ d: CandidateVerdict.Disposition) -> String {
        switch d {
        case .chosen:            return "선택"
        case .candidate:         return "후보"
        default:                 return "제외"
        }
    }

    private func renderJSON(_ e: SelectionExplanation) throws -> String {
        var candidates: [[String: Any]] = []
        for v in e.verdicts {
            var row: [String: Any] = ["id": v.id, "reason": v.reason]
            if let h = v.headroom { row["headroom"] = h }
            switch v.disposition {
            case .chosen:                 row["disposition"] = "chosen"
            case .candidate(let tier):    row["disposition"] = "candidate"; row["tier"] = tier
            case .alreadyTried:           row["disposition"] = "already_tried"
            case .autoSwitchOff(let u):   row["disposition"] = "auto_switch_off"
                                          row["usable_now"] = u
            case .invalid:                row["disposition"] = "invalid"
            case .cooling:                row["disposition"] = "cooling"
            case .unknownAccount:         row["disposition"] = "unknown_account"
            }
            candidates.append(row)
        }
        var result: [String: Any] = [:]
        switch e.result {
        case .selected(let s):
            result = ["kind": "selected", "account": s.accountID,
                      "plan": s.plan.rawValue, "cross_plan": s.isCrossPlan]
        case .wait(let until):
            result = ["kind": "wait", "until": ISO8601DateFormatter().string(from: until)]
        case .exhausted(let unblockable):
            result = ["kind": "exhausted", "unblockable": unblockable]
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["result": result, "candidates": candidates],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
