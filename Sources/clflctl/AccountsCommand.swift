import Foundation
import ArgumentParser
import ClflCore
import ClflStore

struct Accounts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "조직 등록과 우선순위",
        subcommands: [List.self, Add.self, Remove.self, Enable.self, Disable.self, Priority.self],
        defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "우선순위 순으로 나열")
        @OptionGroup var paths: Paths

        func run() async throws {
            let doc = try await paths.accountsFile().load()
            let codes = shortCodes(for: doc.priority)
            let store = paths.credentials

            let rows = doc.priority.enumerated().map { index, id -> [String] in
                let a = doc.accounts[id]!
                return ["\(index + 1)", codes[id] ?? "?", id, a.plan.rawValue,
                        a.credentialKind.rawValue,
                        a.autoSwitch ? "켬" : "끔",
                        store.hasCredential(for: id) ? "있음" : "없음",
                        stamp(a.tokenCreatedAt)]
            }
            print(renderTable(["#", "코드", "id", "플랜", "자격증명", "자동전환", "Keychain", "등록"],
                              rows))
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "조직을 등록한다. 토큰은 stdin 으로 받는다",
            discussion: """
            토큰을 인자로 받지 않는다. argv 는 셸 히스토리에 남는다.

              pbpaste | clflctl accounts add team1 --plan team
              claude setup-token | tail -1 | clflctl accounts add team1
            """)
        @OptionGroup var paths: Paths

        @Argument(help: "우선순위 체인에서 쓸 식별자") var id: String
        @Option(help: "team 또는 enterprise") var plan: String = "team"
        @Option(name: .customLong("base-url"), help: "기본은 https://api.anthropic.com")
        var baseURL: String?
        @Option(help: "메모") var note: String?

        func run() async throws {
            guard let plan = Plan(rawValue: plan) else {
                throw CheckFailed(description: "plan 은 team 또는 enterprise 다")
            }
            // claude setup-token 은 파이프로 넘겨도 ANSI 제어 문자를 뿜는다.
            // 사용자가 grep 파이프라인을 만들 것이 아니라 도구가 뽑아낸다
            let stdin = String(decoding: FileHandle.standardInput.readDataToEndOfFile(),
                               as: UTF8.self)
            let raw: String
            do {
                let extracted = try extractToken(from: stdin)
                raw = extracted.text
                if extracted.wasCleaned {
                    print("  정리    제어 문자와 장식을 걷어내고 토큰을 뽑았다")
                }
            } catch let error as TokenHygieneError {
                throw CheckFailed(description: error.description)
            }

            // 앞이 { 면 auth login 캡처, 아니면 setup-token 문자열이다
            let credential: StoredCredential
            let kind: CredentialKind
            let fingerprintSource: String
            if raw.hasPrefix("{") {
                // 추출 단계에서 이미 완전한 블록임을 확인했다
                let parsed = OAuthCredential(claudeAiOauthJSON: Data(raw.utf8))!
                credential = .oauth(json: Data(raw.utf8))
                kind = .oauth
                fingerprintSource = parsed.accessToken
                print("  종류    auth login 캡처")
                print("  스코프  \(parsed.scopes.joined(separator: " "))")
                print("  만료    \(stamp(parsed.expiresAt))")
                if !parsed.canReadUsageAPI {
                    print("  주의:   user:profile 이 없어 모델별 주간 한도를 읽지 못한다")
                }
            } else {
                credential = .longLived(token: raw)
                kind = .longLived
                fingerprintSource = raw
                print("  종류    setup-token")
            }

            let fingerprint = tokenFingerprint(fingerprintSource)
            var doc = try await paths.accountsFile().load()
            if let clash = doc.accounts.values.first(where: {
                $0.tokenFingerprint == fingerprint && $0.id != id
            }) {
                throw CheckFailed(description: "같은 토큰이 \(clash.id) 로 이미 등록돼 있다")
            }

            doc.accounts[id] = Account(
                id: id, plan: plan,
                baseURL: baseURL.flatMap(URL.init(string:)),
                note: note, credentialKind: kind,
                tokenCreatedAt: Date(), tokenFingerprint: fingerprint)
            try paths.credentials.store(credential, for: id)
            try await paths.accountsFile().save(doc)
            print("  등록했다 \(id) (\(plan.rawValue))")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "조직과 자격증명을 지운다")
        @OptionGroup var paths: Paths
        @Argument var id: String

        func run() async throws {
            var doc = try await paths.accountsFile().load()
            guard doc.accounts.removeValue(forKey: id) != nil else {
                throw CheckFailed(description: "\(id) 는 등록돼 있지 않다")
            }
            try await paths.accountsFile().save(doc)
            try paths.credentials.remove(id)
            print("  지웠다 \(id)")
        }
    }

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "자동 전환 대상에 넣는다")
        @OptionGroup var paths: Paths
        @Argument var id: String
        func run() async throws { try await setAutoSwitch(true, id, paths) }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "자동 전환에서 뺀다. 조직과 자격증명은 그대로 남는다")
        @OptionGroup var paths: Paths
        @Argument var id: String
        func run() async throws { try await setAutoSwitch(false, id, paths) }
    }

    struct Priority: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "우선순위를 다시 쓴다. 빠뜨린 조직은 뒤에 붙는다")
        @OptionGroup var paths: Paths
        @Argument(help: "우선순위 순서대로 나열") var ids: [String]

        func run() async throws {
            var doc = try await paths.accountsFile().load()
            if let unknown = ids.first(where: { doc.accounts[$0] == nil }) {
                throw CheckFailed(description: "\(unknown) 는 등록돼 있지 않다")
            }
            doc.priority = ids
            try await paths.accountsFile().save(doc)
            let saved = try await paths.accountsFile().load()
            print("  " + saved.priority.joined(separator: " > "))
        }
    }
}

private func setAutoSwitch(_ value: Bool, _ id: String, _ paths: Paths) async throws {
    var doc = try await paths.accountsFile().load()
    guard var account = doc.accounts[id] else {
        throw CheckFailed(description: "\(id) 는 등록돼 있지 않다")
    }
    account.autoSwitch = value
    doc.accounts[id] = account
    try await paths.accountsFile().save(doc)

    let remaining = doc.accounts.values.filter(\.autoSwitch).count
    print("  \(id) 자동 전환 \(value ? "켬" : "끔")")
    if remaining == 0 {
        print("  주의:   자동 전환 대상이 0개다. 모든 요청이 실패한다")
    }
}
