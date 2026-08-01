import Foundation

/// 요청과 응답 헤더의 순수 변환. docs/porting/01-headers-and-auth.md
///
/// 적용 순서는 고정이다.
///   stripClientHopByHop -> rewriteAuth -> injectAnthropicVersion
public enum ProxyHeaders {

    /// 업스트림 전송 전 클라이언트 요청에서 제거.
    /// authorization/x-api-key 는 우리 토큰으로 대체되므로 클라이언트 값은 오염된
    /// 것으로 간주한다. host 는 업스트림 URL 이 자체 Host 를 정의.
    /// 나머지는 RFC 7230 6.1 hop-by-hop.
    public static let requestBlocklist: Set<String> = [
        "authorization", "x-api-key", "host",
        "connection", "keep-alive",
        "proxy-authenticate", "proxy-authorization", "proxy-connection",
        "te", "trailer", "transfer-encoding", "upgrade",
    ]

    /// 클라이언트로 되돌릴 때 제거. 요청 쪽과 달리 proxy-connection, host, auth 없음.
    public static let responseBlocklist: Set<String> = [
        "connection", "keep-alive",
        "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade",
    ]

    public static let oauthTokenPrefix = "sk-ant-oat01-"

    /// Anthropic 이 Authorization: Bearer 로 OAuth 토큰을 받기 위해 요구하는 플래그.
    /// 없으면 401 "OAuth authentication is currently not supported."
    public static let oauthBetaFlag = "oauth-2025-04-20"

    public static let defaultAnthropicVersion = "2023-06-01"

    public static func stripClientHopByHop(_ headers: HeaderBag) -> HeaderBag {
        _ = headers
        fatalError("TODO: requestBlocklist 를 제거하고 키를 소문자화한다")
    }

    /// 최우선 규칙. OAuth 토큰을 x-api-key 로 보내면 401 "invalid x-api-key" 가 나고
    /// 모든 조직이 차례로 invalid 처리되어 체인이 즉시 소진된다.
    /// docs/porting/01-headers-and-auth.md 2절
    public static func rewriteAuth(_ headers: HeaderBag, token: String) -> HeaderBag {
        _ = (headers, token)
        fatalError("TODO: oat01 이면 Bearer + anthropic-beta 병합, 아니면 x-api-key")
    }

    /// 기존 값 순서를 보존하며 플래그를 병합. 이미 있으면 중복 추가하지 않음(멱등).
    public static func mergeBetaFlag(existing: String?, flag: String) -> String {
        _ = (existing, flag)
        fatalError("TODO")
    }

    /// 클라이언트가 보낸 값이 있으면 그대로 보존하고, 없을 때만 기본값 주입.
    public static func injectAnthropicVersion(
        _ headers: HeaderBag,
        default version: String = defaultAnthropicVersion
    ) -> HeaderBag {
        _ = (headers, version)
        fatalError("TODO")
    }

    /// 프로덕션 경로는 항상 clientDecodedBody: true 로 부른다. 업스트림 자동 해제를
    /// 켜야 SSE peek 이 평문을 볼 수 있고, 그러면 content-encoding 을 떼야 한다.
    /// false 는 해제하지 않은 경로를 재현하는 회귀 가드용.
    /// docs/porting/01-headers-and-auth.md 5절
    public static func pickResponseHeaders(
        _ upstream: HeaderBag,
        clientDecodedBody: Bool
    ) -> HeaderBag {
        _ = (upstream, clientDecodedBody)
        fatalError("TODO: responseBlocklist + content-length + (조건부) content-encoding 제거")
    }

    /// URLComponents 를 쓰지 말 것. 정규화가 기업 게이트웨이의 path prefix 를
    /// 망가뜨리고 query 를 재인코딩한다. 문자열 결합이 의도된 구현.
    public static func buildUpstreamURL(baseURL: String, requestURI: String) -> String {
        _ = (baseURL, requestURI)
        fatalError("TODO")
    }
}
