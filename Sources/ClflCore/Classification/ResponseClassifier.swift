import Foundation

/// 스왑할지 통과시킬지 결정하는 유일한 지점.
/// docs/porting/02-response-classification.md 2절
///
/// 통과시켜야 하는 것: 200, 529 overloaded, 500 api_error, 스왑 집합에 없는
/// error.type 의 429, 인증이 아닌 body 의 401, 파싱 불가 body.
public func classifyResponse(_ input: ClassifyInput) -> SwapTrigger? {
    _ = input
    fatalError("""
        TODO: extractErrorType -> nil 이면 통과.
        rate_limit/session_limit 은 status 429 또는 첫 SSE 이벤트가 error 일 때만.
        authentication 은 status 401 또는 첫 SSE 이벤트가 error 일 때만.
        200 으로 시작한 스트림의 첫 프레임이 event: error 인 경우가 실제로 있다.
        """)
}

/// 첫 SSE 이벤트 또는 버퍼 본문에서 `error.type` 을 꺼낸다.
/// 어떤 실패든 nil -> passthrough. 방어적 계약이다.
func extractErrorType(_ input: ClassifyInput) -> String? {
    _ = input
    fatalError("TODO")
}
