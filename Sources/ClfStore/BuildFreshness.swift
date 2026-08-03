import Foundation

/// 개발용 바이너리가 소스보다 낡았는지 본다.
///
/// `~/.local/bin/clfctl` 이 `.build/release/clfctl` 를 직접 가리키는 심볼릭
/// 링크라 조용히 낡는다. 디버그 빌드로 검증해놓고 릴리스를 안 올리면 다음
/// 실행에서 옛 동작을 보게 된다.
///
/// 커밋 해시가 아니라 수정 시각을 본다. 커밋을 안 한 변경도 잡히고, 빌드
/// 플러그인으로 해시를 박아 넣을 필요도 없다.
///
/// 한 가지 흠. 내용은 그대로 두고 `touch` 만 하면 SPM 이 재링크를 건너뛰어
/// 경고가 안 사라진다. 다음 실제 수정 때 풀린다. 다시 빌드해서 손해 볼 것은
/// 없으므로 그대로 둔다.
public enum BuildFreshness {
    /// 컴파일 시점 경로에서 거슬러 올라간 패키지 루트.
    /// 배포된 바이너리에는 이 경로가 없으므로 `warning` 이 조용해진다.
    public static var packageRoot: URL? {
        // <root>/Sources/ClfStore/BuildFreshness.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Package.swift").path) ? root : nil
    }

    /// 소스가 바이너리보다 새로우면 경고 문구, 아니면 nil.
    ///
    /// **경고만 한다. 막지 않는다.** 낡은 바이너리로도 하려던 일은 되고,
    /// 검사 하나 때문에 도구가 안 뜨면 안 된다.
    public static func warning(executable: URL, sourceRoot: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceRoot.appendingPathComponent("Package.swift").path),
              let built = modified(executable),
              let changed = newestSource(under: sourceRoot),
              changed > built
        else { return nil }

        return """
              주의: clfctl 이 낡았다. 소스가 \(age(seconds: changed.timeIntervalSince(built))) 더 새롭다
                    swift build -c release
              """
    }

    /// 분으로만 말하면 열흘 묵은 빌드가 14400분으로 나온다. 못 읽는다.
    static func age(seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60:    return "1분 안쪽"
        case ..<3600:  return "\(Int(seconds / 60))분"
        case ..<86400: return "\(Int(seconds / 3600))시간"
        default:       return "\(Int(seconds / 86400))일"
        }
    }

    /// `Sources` 와 `Package.swift` 만 본다. `.build` 는 항상 최신이라 세면
    /// 늘 낡았다고 나오고, `docs` 와 `Tests` 는 바이너리 동작과 무관하다.
    static func newestSource(under root: URL) -> Date? {
        var newest = modified(root.appendingPathComponent("Package.swift"))
        let sources = root.appendingPathComponent("Sources")
        let walker = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
        while let url = walker?.nextObject() as? URL {
            // 디렉토리는 세지 않는다. 파일이 추가되면 그 파일 시각으로 잡힌다
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false,
                  let date = modified(url) else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        return newest
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
