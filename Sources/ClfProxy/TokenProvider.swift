import Foundation
import ClfCore
import ClfStore

/// 요청 직전에 유효한 접근 토큰을 낸다.
/// docs/design/07-oauth-credentials.md 4절
///
/// longLived 는 저장값 그대로, oauth 는 만료가 가까우면 먼저 갱신한 뒤.
/// 프록시가 업스트림에 붙이는 것은 두 경우 모두 접근 토큰 하나이므로
/// rewriteAuth 는 종류에 따라 갈리지 않는다.
public actor TokenProvider {
    /// 요청이 오래 걸려도 도중에 만료되지 않게 하는 여유.
    public static let refreshMargin: TimeInterval = 300

    public init(store: any CredentialStoring, refresher: OAuthRefresher, clock: any Clock) {
        _ = (store, refresher, clock)
        fatalError("TODO")
    }

    /// 계정당 단일 비행. 동시 요청이 같은 조직의 갱신을 중복 실행하지 않게 한다.
    /// 뒤늦게 온 호출자는 진행 중인 갱신을 기다렸다가 같은 결과를 받는다.
    public func accessToken(for id: AccountID) async throws -> String {
        _ = id
        fatalError("TODO")
    }

    /// 401 을 맞았을 때 부른다. 만료 여유와 무관하게 즉시 갱신을 시도한다.
    /// 요청 하나에서 조직 하나당 한 번만 불러야 한다. 무한 루프 가드는 호출자 책임.
    public func forceRefresh(for id: AccountID) async -> RefreshOutcome {
        _ = id
        fatalError("TODO")
    }
}
