import Foundation

/// 임시 파일 + rename 으로 원자적 교체. 모드 0600.
/// docs/design/02-domain-model.md 6절
public func atomicWrite(_ data: Data, to url: URL) throws {
    _ = (data, url)
    fatalError("TODO")
}

/// 앱 데이터 디렉토리. ~/Library/Application Support/clfl/
public func appSupportDirectory() throws -> URL {
    fatalError("TODO")
}
