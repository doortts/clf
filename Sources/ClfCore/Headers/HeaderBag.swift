/// 케이스 무시 헤더 백. 키는 항상 소문자로 보관한다.
///
/// NIO 의 `HTTPHeaders` 는 조회만 케이스 무시고 순회 시 원본 케이싱을 보존한다.
/// `hasPrefix("anthropic-ratelimit-")` 같은 순회 기반 규칙이 있으므로 경계에서
/// 이 타입으로 한 번 정규화하고 들어간다.
/// docs/porting/01-headers-and-auth.md 0절
public struct HeaderBag: Sendable, Hashable {
    public private(set) var storage: [String: String]

    public init(_ storage: [String: String] = [:]) {
        self.storage = storage.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    }

    public subscript(key: String) -> String? {
        get { storage[key.lowercased()] }
        set { storage[key.lowercased()] = newValue }
    }
}
