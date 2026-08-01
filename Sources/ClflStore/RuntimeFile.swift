import Foundation
import ClflCore

/// runtime.json. 조직별 런타임 상태 전체.
///
/// 재시작마다 잃으면 소진된 (조직, 모델) 쌍을 다시 프로브해 429 캐스케이드를
/// 반복하고, 401 로 무효화한 조직이 되살아나고, 5시간 쿨다운이 리셋되고, UI 게이지가
/// 첫 요청 전까지 빈다. docs/design/02-domain-model.md 6절
///
/// 쓰기는 1초 debounce 로 합친다. 요청마다 쓰지 않는다.
public actor RuntimeFile {
    public init(directory: URL) { _ = directory; fatalError("TODO") }

    public func load() throws -> [AccountID: AccountRuntime] { fatalError("TODO") }

    /// debounce 대상. 즉시 쓰지 않고 예약한다.
    public func schedule(_ runtime: [AccountID: AccountRuntime]) { _ = runtime; fatalError("TODO") }

    /// 종료 시퀀스에서 부른다.
    public func flush() throws { fatalError("TODO") }

    /// 7일 지난 modelCooldowns 항목을 정리한다. 시작 시퀀스에서 부른다.
    public func pruneExpiredCooldowns(now: Date) { _ = now; fatalError("TODO") }
}
