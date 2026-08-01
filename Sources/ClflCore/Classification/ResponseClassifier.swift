import Foundation

/// 스왑할지 통과시킬지 결정하는 유일한 지점.
/// docs/porting/02-response-classification.md 2절
///
/// 통과시켜야 하는 것: 200, 529 overloaded, 500 api_error, 스왑 집합에 없는
/// error.type 의 429, 인증이 아닌 body 의 401, 파싱 불가 body.
public func classifyResponse(_ input: ClassifyInput) -> SwapTrigger? {
    guard let errorType = extractErrorType(input) else { return nil }   // 파싱 실패 = 통과

    // 200 으로 시작한 스트림의 첫 프레임이 event: error 인 경우가 실제로 있다.
    // status 만 보면 통째로 놓친다.
    let isStreamingError = input.firstSSEEvent?.event == "error"

    switch errorType {
    case "rate_limit_error", "session_limit_error":
        guard input.status == 429 || isStreamingError else { return nil }
        let reset = resolveResetEpoch(input.headers, now: input.now)
        return errorType == "rate_limit_error"
            ? .rateLimit(accountID: input.accountID, resetEpoch: reset, sessionID: input.sessionID)
            : .sessionLimit(accountID: input.accountID, resetEpoch: reset, sessionID: input.sessionID)

    case "authentication_error":
        guard input.status == 401 || isStreamingError else { return nil }
        return .authentication(accountID: input.accountID, sessionID: input.sessionID)

    default:
        return nil
    }
}

/// 첫 SSE 이벤트 또는 버퍼 본문에서 `error.type` 을 꺼낸다.
/// 어떤 실패든 nil -> passthrough. Anthropic 형태가 아닌 응답을 건드리지 않기 위한
/// 방어적 계약이다.
func extractErrorType(_ input: ClassifyInput) -> String? {
    let raw: Data?
    if let event = input.firstSSEEvent {
        raw = Data(event.data.utf8)
    } else {
        raw = input.body
    }
    guard let raw, !raw.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: raw),
          let root = object as? [String: Any],
          let error = root["error"] as? [String: Any],
          let type = error["type"] as? String
    else { return nil }
    return type
}
