import Foundation

/// 한 대화를 여러 계정이 가리키는 것을 찾는다.
///
/// 11절이 정한 규칙은 **한 대화를 한 계정만 가리키는 것**이다. 그래서 넘기기는
/// 복사가 아니라 옮기기이고, 먼저 넣고 나중에 지운다. 그런데 지금 디스크가 그
/// 규칙을 어기고 있다. 규칙이 주석과 문서에만 있어서 어긴 것을 아무도 잡지
/// 않는다.
///
/// 겹치면 두 창이 같은 트랜스크립트에 쓸 수 있고, 겹친 쪽으로 넘기려 하면
/// 이름이 부딪혀 막힌다. docs/design/13-multi-instance.md 12절
public enum SessionDuplicate {
    /// 한 대화를 가리키는 레코드 하나.
    public struct Owner: Sendable, Equatable {
        public let account: String
        public let fileName: String
        public let transcriptID: String

        public init(account: String, fileName: String, transcriptID: String) {
            self.account = account
            self.fileName = fileName
            self.transcriptID = transcriptID
        }
    }

    /// 두 계정 이상이 가리키는 대화 하나.
    public struct Shared: Sendable, Equatable, Identifiable {
        public let transcriptID: String
        public let accounts: [String]
        public var id: String { transcriptID }

        public init(transcriptID: String, accounts: [String]) {
            self.transcriptID = transcriptID
            self.accounts = accounts
        }
    }

    /// 규칙을 어긴 대화만. 지킨 것은 넣지 않는다.
    ///
    /// 한 계정 안에 레코드가 둘이어도 계정은 하나다. 그것은 이 규칙이 다루는
    /// 문제가 아니라서 **계정을 겹치지 않게 센다.**
    public static func find(_ owners: [Owner]) -> [Shared] {
        var byConversation: [String: Set<String>] = [:]
        for owner in owners where !owner.transcriptID.isEmpty {
            byConversation[owner.transcriptID, default: []].insert(owner.account)
        }
        return byConversation
            .filter { $0.value.count >= 2 }
            // 같은 상태가 늘 같게 보여야 한다. 순서를 고정한다
            .map { Shared(transcriptID: $0.key, accounts: $0.value.sorted()) }
            .sorted { $0.transcriptID < $1.transcriptID }
    }

    /// 계정 폴더들을 훑는다. 레코드의 작은 JSON 만 읽는다.
    public static func scan(stores: [SessionStore]) -> [Shared] {
        find(stores.flatMap { store in
            store.records().compactMap { record in
                record.transcriptID.map {
                    Owner(account: store.account, fileName: record.fileName, transcriptID: $0)
                }
            }
        })
    }

    public static let clean = "겹치는 것 없음"

    /// doctor 표에 들어갈 한 칸.
    ///
    /// 상태만 찍지 않고 **무엇을 하면 풀리는지** 같이 적는다. 어느 대화인지도
    /// 말해야 손을 댈 수 있는데, 표 한 칸이라 앞의 몇 개만 적는다.
    ///
    /// uuid 는 앞 8자만 쓴다. 통째로 넣으면 한 줄이 130자를 넘어 표가 깨진다.
    /// 문서도 그 길이로 부른다.
    public static func detail(_ shared: [Shared], limit: Int = 2) -> String {
        guard !shared.isEmpty else { return clean }
        let names = shared.prefix(limit).map { String($0.transcriptID.prefix(8)) }
            .joined(separator: ", ")
        let rest = shared.count - min(limit, shared.count)
        let tail = rest > 0 ? ", 외 \(rest)개" : ""
        return "\(shared.count)개가 여러 계정에 겹쳐 있다 (\(names)\(tail)). 한쪽 레코드를 지운다"
    }
}
