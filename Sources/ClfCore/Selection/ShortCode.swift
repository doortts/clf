import Foundation

/// 메뉴바 전용 축약 코드. 순수 함수이므로 조직 집합이 같으면 결과가 항상 같다.
/// docs/design/02-domain-model.md 7절
///
/// 규칙
///   - 이름에 "team" 이 들어가면 그들끼리 알파벳순 정렬해 T1, T2, ...
///     번호는 이름 안의 숫자가 아니라 정렬 순서에서 나온다
///   - 나머지는 앞 2글자를 대문자로
///   - 앞 2글자가 겹치면 첫 글자 + 정렬 순서로 대체
///
/// 주의: 정렬 순서로 번호를 매기므로 조직을 추가하면 기존 코드가 밀린다.
/// 설정 창의 목록에 코드를 함께 표시해 언제든 확인할 수 있게 한다.
public func shortCodes(for ids: [AccountID]) -> [AccountID: String] {
    var out: [AccountID: String] = [:]

    let isTeam = { (id: AccountID) in id.lowercased().contains("team") }
    let teams  = ids.filter(isTeam).sorted()
    let others = ids.filter { !isTeam($0) }.sorted()

    for (index, id) in teams.enumerated() { out[id] = "T\(index + 1)" }

    // 앞 2글자로 묶고, 겹치는 묶음만 첫 글자 + 순번으로 대체한다.
    // others 가 이미 정렬돼 있으므로 묶음 안의 순번도 결정적이다.
    var byPrefix: [String: [AccountID]] = [:]
    for id in others {
        byPrefix[id.prefix(2).uppercased(), default: []].append(id)
    }
    for (prefix, group) in byPrefix {
        if group.count == 1 {
            out[group[0]] = prefix
        } else {
            let head = prefix.prefix(1)
            for (index, id) in group.enumerated() { out[id] = "\(head)\(index + 1)" }
        }
    }
    return out
}

/// 활성 조직을 뺀 나머지 중 가장 최근에 쓴 것.
/// 전환 직후에는 방금 한도에 걸려 떠나온 조직이 여기 잡힌다.
public func mostRecentOther(
    runtime: [AccountID: AccountRuntime],
    activeID: AccountID?
) -> AccountID? {
    runtime
        .filter { $0.key != activeID && $0.value.lastUsedAt != nil }
        .max { ($0.value.lastUsedAt ?? .distantPast) < ($1.value.lastUsedAt ?? .distantPast) }?
        .key
}
