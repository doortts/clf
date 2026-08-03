import Foundation

/// 시계는 언제나 주입한다. ClfCore 안에서 `Date()` 를 부르는 곳은 없어야 한다.
/// docs/design/01-architecture.md 2절
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

/// 테스트용 고정 시계. 쿨다운 경계값을 결정적으로 검증한다.
public struct FixedClock: Clock {
    public var now: Date
    public init(_ now: Date) { self.now = now }
}
