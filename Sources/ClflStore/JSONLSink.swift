import Foundation
import ClflCore

/// best-effort append sink. **throws 하지 않는다.**
///
/// 로그 실패가 요청 경로를 막지 않는 것을 규율이 아니라 타입으로 강제한다.
/// 호출부에서 `try?` 를 쓰는 습관에 기대면 언젠가 새어나온다.
/// docs/design/04-implementation.md 6절
public protocol EventSinking: Sendable {
    func append(_ event: RoutingEvent)
    func append(_ usage: UsageRecord)
}

public actor JSONLSink: EventSinking {
    public init(directory: URL) { _ = directory; fatalError("TODO") }

    nonisolated public func append(_ event: RoutingEvent) { _ = event }
    nonisolated public func append(_ usage: UsageRecord) { _ = usage }
}
