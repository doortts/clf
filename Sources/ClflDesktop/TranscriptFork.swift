import Foundation

/// 트랜스크립트를 다른 계정으로 넘기려고 복제한다.
///
/// 데스크톱 앱의 Fork 와 같은 방식이다. **줄을 그대로 복사하고 uuid 를
/// 안 고친다.** 앱이 `copyFile` 로 하는 그 일이다.
///
/// 다만 하나는 본다. 짝 없는 `tool_use` 로 끝난 파일은 복사해도 안 열린다.
/// API 가 `tool_use` 에 대응하는 `tool_result` 를 요구하기 때문이다. 그 경우만
/// 꼬리를 떼어낸다. 넘기기를 누르는 시점에는 대개 세션이 멈춰 있어서 걸릴
/// 일이 드물지만, 걸리면 사용자가 이유를 알 방법이 없다.
/// docs/design/13-multi-instance.md
public enum TranscriptFork {
    public static let marker = "[넘김]"

    /// 앞에서부터 몇 줄을 가져갈지.
    ///
    /// 마지막 메시지가 짝 없는 도구 호출이면 그 줄부터 끝까지 뗀다. 뒤에 딸린
    /// 메타 줄도 함께 뗀다. 남겨 두면 없는 항목을 가리킨다.
    public static func keepCount(_ lines: [Data]) -> Int {
        var end = lines.count
        while end > 0 {
            // 쓰다 만 줄이 꼬리에 있으면 먼저 뗀다
            while end > 0, !parse(lines[end - 1]).parsed { end -= 1 }
            guard end > 0, let last = lastAssistantIndex(lines, before: end) else { return end }

            // 그 호출의 결과는 뒤에 온다. 남길 범위 안에서만 찾는다
            var seen: Set<String> = []
            for i in (last + 1)..<end { seen.formUnion(parse(lines[i]).results) }
            let uses = parse(lines[last]).uses
            if uses.isEmpty || uses.isSubset(of: seen) { return end }
            end = last
        }
        return 0
    }

    /// 복사본임을 알리는 제목 줄. 파일 끝에 붙인다.
    ///
    /// 앱은 `customTitle` 을 `aiTitle` 보다 먼저 본다. 그래서 이 한 줄이
    /// 목록에 뜨는 이름을 정한다.
    public static func titleLine(sessionID: String, title: String) -> Data? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 두 번 넘겨도 표시가 겹치지 않는다
        let marked = clean.hasPrefix(marker) ? clean
            : (clean.isEmpty ? marker : "\(marker) \(clean)")
        return try? JSONSerialization.data(
            withJSONObject: ["type": "custom-title", "sessionId": sessionID,
                             "customTitle": marked],
            options: [.sortedKeys])
    }

    // MARK: 안쪽

    private struct Entry {
        var type = ""
        var uses: Set<String> = []
        var results: Set<String> = []
        var parsed = false
    }

    /// 마지막 assistant 줄. 사용자 줄과 메타 줄은 건너뛴다.
    ///
    /// 사용자 줄에서 멈추면 안 된다. 그 앞의 assistant 가 부른 도구 중 일부만
    /// 돌아온 경우를 놓친다.
    private static func lastAssistantIndex(_ lines: [Data], before end: Int) -> Int? {
        for i in stride(from: end - 1, through: 0, by: -1)
        where parse(lines[i]).type == "assistant" { return i }
        return nil
    }

    private static func parse(_ line: Data) -> Entry {
        var e = Entry()
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return e }
        e.parsed = true
        e.type = root["type"] as? String ?? ""
        guard let content = (root["message"] as? [String: Any])?["content"] as? [[String: Any]]
        else { return e }
        for block in content {
            switch block["type"] as? String {
            case "tool_use":    (block["id"] as? String).map { e.uses.insert($0) }
            case "tool_result": (block["tool_use_id"] as? String).map { e.results.insert($0) }
            default: break
            }
        }
        return e
    }
}

extension TranscriptFork {
    public struct Copy: Sendable, Equatable {
        public let cliSessionID: String
        public let path: URL
        /// 꼬리에서 떼어낸 줄 수. 대개 0 이다.
        public let dropped: Int
    }

    /// 트랜스크립트를 새 uuid 로 복제한다. 원본은 읽기만 한다.
    public static func copy(transcript source: URL, newID: String = UUID().uuidString.lowercased(),
                            title: String) throws -> Copy {
        guard let data = FileManager.default.contents(atPath: source.path) else {
            throw SafeStorageError(description: "트랜스크립트를 못 읽었다")
        }
        // 마지막 개행 뒤의 빈 조각은 줄이 아니다
        let newline = UInt8(ascii: "\n")
        var lines: [Data] = data
            .split(separator: newline, omittingEmptySubsequences: false)
            .map { Data($0) }
        if lines.last?.isEmpty == true { lines.removeLast() }

        let keep = keepCount(lines)
        guard keep > 0 else {
            throw SafeStorageError(description: "넘길 대화가 없다")
        }
        var out = Data()
        for line in lines.prefix(keep) { out.append(line); out.append(0x0A) }
        // 원본 줄의 sessionId 를 그대로 두므로 제목 줄도 같은 값을 쓴다
        let inner = sessionID(in: lines.prefix(keep)) ?? newID
        if let title = titleLine(sessionID: inner, title: title) {
            out.append(title); out.append(0x0A)
        }

        let dest = source.deletingLastPathComponent()
            .appendingPathComponent("\(newID).jsonl")
        try out.write(to: dest, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: dest.path)
        return Copy(cliSessionID: newID, path: dest, dropped: lines.count - keep)
    }

    /// 파일 안에 적힌 세션 id. 파일 이름과 다를 수 있다.
    static func sessionID(in lines: some Sequence<Data>) -> String? {
        for line in lines {
            if let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let id = root["sessionId"] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    /// 목록에 뜨는 이름. `customTitle` 이 `aiTitle` 을 이긴다.
    public static func title(of source: URL) -> String {
        guard let data = FileManager.default.contents(atPath: source.path) else { return "" }
        var custom = "", ai = ""
        let newline = UInt8(ascii: "\n")
        for line in data.split(separator: newline, omittingEmptySubsequences: true) {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any] else { continue }
            if let t = root["customTitle"] as? String, !t.isEmpty { custom = t }
            if let t = root["aiTitle"] as? String, !t.isEmpty { ai = t }
        }
        return custom.isEmpty ? ai : custom
    }
}
