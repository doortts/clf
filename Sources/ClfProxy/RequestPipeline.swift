import Foundation
import ClfCore
import ClfStore

/// 요청 하나의 전 생애. docs/design/03-request-flow.md 1절
///
/// 불변식
///   - 통과 판정 전에는 클라이언트 소켓에 한 바이트도 쓰지 않는다.
///     이 한 줄이 peek 설계 전체를 강제한다
///   - Router actor 는 업스트림 실행 동안 잠기지 않는다
public struct RequestPipeline: Sendable {
    /// 이 값을 넘으면 재전송할 사본을 들 수 없어 스왑이 불가능하다.
    /// 순수 텍스트 1M 컨텍스트는 4~5MB 라 여유가 있지만 base64 이미지가 부풀린다.
    public static let maxRetryBodyBytes = 8 * 1024 * 1024

    /// 풀이 순간 비었을 때 즉시 실패시키지 않고 기다리는 예산.
    /// 일시 과부하 429 가 연쇄로 터지는 시작 구간을 흡수한다.
    public static let poolGraceSeconds: TimeInterval = 15

    public init(
        router: Router,
        tokens: TokenProvider,
        executor: any UpstreamExecuting,
        usage: UsageRefresher,
        events: any EventSinking
    ) {
        _ = (router, tokens, executor, usage, events)
        fatalError("TODO")
    }

    /// 스왑 루프.
    ///
    /// 401 분기가 자격증명 종류에 따라 갈린다. oauth 이고 이번 요청에서 이 조직에
    /// 대해 아직 갱신하지 않았으면, 갱신 1회 후 **같은 조직으로 재시도**하고
    /// tried 에 넣지 않는다. 만료된 토큰이 조직을 태우지 않게 하는 것이 smooth 의
    /// 상당 부분이다. docs/design/07-oauth-credentials.md 5절
    public func handle(
        method: String,
        uri: String,
        headers: HeaderBag,
        body: [UInt8],
        client: any ClientResponseWriting
    ) async {
        _ = (method, uri, headers, body, client)
        fatalError("TODO")
    }
}

/// X-Claude-Session-Id 가 처음 관측된 요청을 대화 시작으로 본다.
///
/// 헤더가 없으면 false 를 반환한다. 판정 불가일 때 선제 전환을 하지 않는 쪽이
/// 안전하다. 캐시를 잘못 버리는 것보다 quota 를 조금 더 쓰는 편이 낫다.
public protocol ConversationStartDetecting: Sendable {
    func isStart(sessionID: SessionID?) -> Bool
}
