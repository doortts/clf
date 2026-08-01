import Foundation
import ArgumentParser
import ClflCore
import ClflStore

/// 무엇이 준비됐고 무엇이 빠졌는지 한 화면에.
///
/// 각 항목은 상태와 함께 **무엇을 하면 풀리는지**를 말한다. 상태만 찍는 점검은
/// 사용자를 문서로 돌려보낼 뿐이다.
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "환경 점검")

    @OptionGroup var paths: Paths

    func run() async throws {
        var rows: [[String]] = []
        var failures = 0

        func check(_ name: String, _ body: () throws -> (ok: Bool, detail: String)) {
            do {
                let (ok, detail) = try body()
                rows.append([ok ? "ok" : "no", name, detail])
                if !ok { failures += 1 }
            } catch {
                rows.append(["no", name, "\(error)"])
                failures += 1
            }
        }

        check("데이터 디렉토리") {
            let url = try paths.data
            let exists = FileManager.default.fileExists(atPath: url.path)
            return (exists, url.path)
        }

        check("Claude 설정 디렉토리") {
            let url = try paths.claude
            let exists = FileManager.default.fileExists(atPath: url.path)
            return (exists, exists ? url.path : "\(url.path) (없음. Claude Code 를 한 번 실행한다)")
        }

        check("settings.json 주입") {
            if let url = try paths.settings().readManagedBaseURL() {
                return (true, url.absoluteString)
            }
            return (false, "없음. clflctl settings install --port 51710")
        }

        check("Keychain 접근") {
            let probe = KeychainCredentialStore(service: "me.clfl.doctor-probe")
            _ = probe.hasCredential(for: "probe")
            return (true, "security CLI 응답함")
        }

        check("Claude CLI 자격증명 슬롯") {
            if let c = try ClaudeKeychainReader().readOAuthCredential() {
                let usage = c.canReadUsageAPI ? "user:profile 있음" : "user:profile 없음"
                return (true, "\(c.subscriptionType ?? "종류 미상"), \(usage)")
            }
            return (false, "비어 있음. claude auth login 후 캡처한다")
        }

        let doc = try await paths.accountsFile().load()
        check("등록된 조직") {
            let auto = doc.accounts.values.filter(\.autoSwitch).count
            if doc.accounts.isEmpty {
                return (false, "없음. clflctl accounts add <id>")
            }
            return (auto > 0,
                    "\(doc.accounts.count)개, 자동 전환 \(auto)개"
                        + (auto == 0 ? " (전부 꺼져 있어 모든 요청이 실패한다)" : ""))
        }

        let store = paths.credentials
        for id in doc.priority {
            check("자격증명 \(id)") {
                store.hasCredential(for: id)
                    ? (true, "있음")
                    : (false, "Keychain 에 없음. clflctl accounts add \(id) 로 다시 넣는다")
            }
        }

        print(renderTable(["", "항목", "상세"], rows))
        print()
        if failures > 0 {
            throw CheckFailed(description: "\(failures)개 항목이 준비되지 않았다")
        }
        print("  전부 통과")
    }
}
