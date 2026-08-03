import Foundation
import ClfCore

/// 요청 경로를 막아도 되는 오류만 여기 있다.
/// 로그 append 실패 같은 부가 I/O 는 EventSinking 이 삼킨다.
public enum ProxyError: Error, Sendable {
    case noAccountAvailable(unblockable: [AccountID])
    case credentialUnavailable(AccountID)
    case upstreamFailed(underlying: any Error)
    case clientDisconnected
    case bodyTooLarge(bytes: Int)
}
