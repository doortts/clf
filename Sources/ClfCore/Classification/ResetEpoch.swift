import Foundation

public let defaultCooldownSeconds = 60

/// 2001-09-09. 이보다 작으면 epoch 가 아니라 delta 로 본다.
public let epochHeuristicMin = 1_000_000_000

/// 쿨다운 해제 시각. docs/porting/02-response-classification.md 3절
///
/// 우선순위
///   1. retry-after (초 단위 delta). Anthropic 의 권위 있는 신호
///   2. 아직 도래하지 않은 anthropic-ratelimit-*-reset 중 **가장 가까운** 것
///   3. now + 60
///
/// max 가 아니라 min 인 이유: Anthropic 은 429 에 추적 중인 모든 창의 reset 을 함께
/// 실어 보낸다. 5시간만 걸린 상황에서도 7일 reset 은 수십 시간 뒤다. max 를 쓰면
/// 실제 쿨다운이 5시간인데 조직을 37시간 이상 퇴장시킨다.
public func resolveResetEpoch(_ headers: HeaderBag, now: Int) -> Int {
    if let raw = headers["retry-after"], let delta = Int(raw), delta >= 0 {
        return now + delta
    }

    var nearest: Int?
    for (key, value) in headers.storage {
        guard key.hasPrefix("anthropic-ratelimit-"), key.hasSuffix("-reset") else { continue }
        guard let epoch = Int(value) else { continue }
        guard epoch >= epochHeuristicMin else { continue }   // delta 를 넣은 경우를 거른다
        guard epoch > now else { continue }                  // 이미 지난 reset 은 건너뛴다
        if nearest == nil || epoch < nearest! { nearest = epoch }
    }
    if let nearest { return nearest }

    return now + defaultCooldownSeconds
}
