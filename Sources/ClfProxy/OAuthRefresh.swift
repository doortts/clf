import Foundation
import ClfStore

/// docs/design/07-oauth-credentials.md 4절
public enum RefreshOutcome: Sendable {
    case renewed(OAuthCredential)
    /// 이 grant 는 다시는 동작하지 않는다. 재등록만이 답이다.
    case rejected
    /// 토큰의 유효성에 대해 아무것도 말하지 않는다. 다음에 다시 해본다.
    case transient
}

public struct OAuthRefresher: Sendable {
    /// Claude Code 의 공개 PKCE 클라이언트. setup-token 의 authorize URL 에 있던
    /// 값과 같다. 비밀이 아니다.
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let tokenURL = "https://console.anthropic.com/v1/oauth/token"

    public init() {}

    /// 판정 규칙
    ///   200 + 파싱 성공                 -> renewed
    ///   4xx + error == "invalid_grant"  -> rejected  (RFC 6749 5.2)
    ///   그 밖의 4xx/5xx/429/타임아웃     -> transient
    ///   **200 인데 우리 파싱 실패**       -> transient (스키마 변경이지 죽은 grant 아님)
    ///
    /// 마지막 줄이 중요하다. 200 을 rejected 로 처리하면 서버가 필드 하나 바꾼 날
    /// 모든 조직이 한꺼번에 재로그인을 요구한다.
    ///
    /// **응답 본문을 절대 로그에 남기지 않는다.** 성공 응답의 첫 바이트가 살아있는
    /// 접근 토큰이고, 진단 로그는 회전돼도 남아 문제 신고에 첨부된다.
    /// 남겨도 되는 것: 상태 코드, 바이트 수, 허용 목록에 있는 OAuth 에러 코드.
    ///
    /// scopes 는 갱신 응답으로 덮어쓰지 않는다. 우리는 그 값으로 Usage API 사용
    /// 가능 여부를 판단하는데, 더 좁은 스코프가 오면 멀쩡한 자격증명의 능력을
    /// 스스로 낮추게 된다.
    public func refresh(_ credential: OAuthCredential) async -> RefreshOutcome {
        _ = credential
        fatalError("TODO")
    }

    static let loggableOAuthErrors: Set<String> = [
        "invalid_grant", "invalid_request", "invalid_client",
        "unauthorized_client", "unsupported_grant_type", "invalid_scope",
    ]
}
