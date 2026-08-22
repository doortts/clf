import Foundation

/// 릴리즈 태그의 버전. `v0.4.0` 과 `0.4.0` 을 같게 읽는다.
///
/// **릴리즈 버전만 받는다.** `make-app.sh` 는 `git describe --tags --always` 를
/// 번들에 박으므로 태그 위가 아닌 빌드에서는 `v0.4.0-3-gabc123` 이나 커밋
/// 해시가 들어온다. 그런 것은 파싱 실패로 떨어뜨려 확인 자체를 건너뛴다.
/// 손으로 빌드해 쓰는 사람에게 릴리즈 버전으로 되돌리자고 권하면 방금 만든
/// 것이 지워진다. docs/design/14-self-update.html 2절
public struct ReleaseVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// 태그 꼴이 정확히 맞을 때만 값이 나온다.
    ///
    /// `v` 접두는 있어도 되고 없어도 된다. 그 밖의 꼬리가 붙으면 nil 이다.
    public static func release(from raw: String) -> ReleaseVersion? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        // 숫자만 받는다. `0-3-gabc123` 같은 꼬리가 여기서 걸린다
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = Int(part)
            else { return nil }
            numbers.append(value)
        }
        return ReleaseVersion(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// 자리별로 견준다. **문자열 비교면 `0.10.0` 이 `0.9.0` 보다 작아진다.**
    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "v\(major).\(minor).\(patch)" }
}

/// 릴리즈 하나. GitHub 응답에서 우리가 쓰는 것만 남긴다.
public struct Release: Equatable, Sendable {
    /// 응답이 준 태그 그대로. 사람 링크를 만들 때 이 문자열을 쓴다.
    public let tag: String
    /// 릴리즈 본문. 카드에 앞 몇 줄이 뜬다.
    public let notes: String
    /// 받을 DMG. 자산이 하나도 안 맞으면 nil 이고 그건 오류가 아니다.
    public let dmg: URL?
    public let bytes: Int64?

    public init(tag: String, notes: String = "", dmg: URL? = nil, bytes: Int64? = nil) {
        self.tag = tag
        self.notes = notes
        self.dmg = dmg
        self.bytes = bytes
    }

    public var version: ReleaseVersion? { ReleaseVersion.release(from: tag) }

    /// 카드에 보일 노트. 빈 줄은 버리고 정해진 줄 수까지만.
    ///
    /// 전문은 **릴리즈 노트** 로 브라우저에서 본다. 320픽셀 안에 스크롤
    /// 영역을 또 만들지 않는다.
    public func noteLines(limit: Int = 3) -> [String] {
        let lines = notes.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(lines.prefix(limit))
    }

    /// 사람이 읽을 크기. 자산에 크기가 없으면 nil 이다.
    public var sizeText: String? {
        guard let bytes, bytes > 0 else { return nil }
        let mb = Double(bytes) / 1_048_576
        return mb < 10 ? String(format: "%.1fMB", mb) : String(format: "%.0fMB", mb)
    }
}

/// 릴리즈 조회의 결과. 응답 코드마다 뜻이 다르다.
public enum ReleaseFetch: Equatable, Sendable {
    case release(Release)
    /// 릴리즈가 하나도 없다. **오류가 아니다.**
    ///
    /// 저장소를 못 읽는 것과 구별해야 한다. 첫 릴리즈가 올라가기 전까지는
    /// 모든 사용자가 이 답을 받으므로 여기서 오류를 띄우면 전원이 빨간 줄을
    /// 본다. docs/design/17-repo-split.html 2절
    case none
    /// ETag 가 맞았다. 익명 한도를 깎지 않는다.
    case notModified
    case failed(String)
}

/// 이 번들에서 업데이트를 확인해도 되는지.
public enum UpdateEligibility: Equatable, Sendable {
    case eligible(ReleaseVersion)
    /// 확인도 안 한다. 사유는 설정에 적는다.
    case developmentBuild(String)
}

public enum UpdateCheck {
    /// 확인 주기. 릴리즈는 자주 바뀌지 않으니 익명 한도를 아낀다.
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    /// 팝오버를 열어서 생기는 확인 사이의 최소 간격.
    ///
    /// 주기만 있으면 새 버전이 나오고 최대 하루 동안 딱지가 안 붙는다. 여는
    /// 것은 사람이 하는 일이라 그때 한 번 보면 그 하루가 없어진다.
    ///
    /// **바닥이 필요하다.** 팝오버는 여닫기가 잦아서 바닥이 없으면 몇 초
    /// 사이에 요청이 여러 번 나간다. 릴리즈는 시간 단위로 바뀌는 것이 아니라
    /// 한 시간이면 충분히 촘촘하다.
    public static let openInterval: TimeInterval = 60 * 60

    /// 지금 확인할 때인가.
    ///
    /// 간격은 부르는 쪽이 정한다. 주기 루프와 팝오버가 같은 도장을 보되 서로
    /// 다른 바닥을 쓴다. 도장이 하나라 잦은 쪽이 뜸한 쪽을 덮어 주고, 팝오버를
    /// 한 번도 안 여는 기계는 주기 루프가 그대로 맡는다.
    ///
    /// 시계가 뒤로 간 경우(마지막 확인이 미래)도 확인한다. 그 도장은 못 믿을
    /// 값이고, 안 그러면 시계를 되돌린 기계가 영영 확인을 안 한다.
    public static func shouldCheck(last: Date?, now: Date,
                                   interval: TimeInterval = checkInterval) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= interval || elapsed < 0
    }

    /// 확인할 자격이 있는 빌드인지 본다.
    public static func eligibility(version raw: String, bundlePath: String) -> UpdateEligibility {
        // 저장소 안에서 바로 실행한 것이다. 릴리즈로 갈아타면 방금 빌드한
        // 것이 사라진다
        if bundlePath.contains("/.build/") {
            return .developmentBuild("저장소에서 바로 실행한 빌드입니다")
        }
        guard let version = ReleaseVersion.release(from: raw) else {
            return .developmentBuild("태그 없이 빌드한 개발 버전입니다 (\(raw))")
        }
        return .eligible(version)
    }

    /// 응답 코드를 결과로 옮긴다.
    public static func classify(status: Int, body: Data?) -> ReleaseFetch {
        switch status {
        case 200:
            guard let body, let release = decode(body) else {
                return .failed("릴리즈 응답을 읽지 못했습니다")
            }
            return .release(release)
        case 304:
            return .notModified
        case 404:
            return .none
        case 401, 403:
            // 익명 한도는 IP 당 시간당 60회다. 다음 차례에 다시 보면 된다
            return .failed("GitHub 이 요청을 거절했습니다 (\(status))")
        case 500...599:
            return .failed("GitHub 이 응답하지 않습니다 (\(status))")
        default:
            return .failed("예상 못한 응답입니다 (\(status))")
        }
    }

    /// 릴리즈 JSON 하나를 읽는다.
    public static func decode(_ data: Data) -> Release? {
        guard let dto = try? JSONDecoder().decode(ReleaseDTO.self, from: data) else { return nil }
        let asset = pickDMG(from: dto.assets ?? [])
        return Release(tag: dto.tagName,
                       notes: dto.body ?? "",
                       dmg: asset.flatMap { URL(string: $0.url) },
                       bytes: asset?.size)
    }

    /// 자산 목록에서 받을 DMG 하나.
    ///
    /// 이름이 `.dmg` 로 **끝나는** 것만 고른다. 확장자가 중간에 든
    /// `clf-v0.5.0.dmg.sha256` 이 걸리면 받아 놓고 마운트에서 실패한다.
    static func pickDMG(from assets: [ReleaseDTO.Asset]) -> ReleaseDTO.Asset? {
        assets.first { $0.name.lowercased().hasSuffix(".dmg") }
    }

    struct ReleaseDTO: Decodable {
        struct Asset: Decodable {
            let name: String
            let url: String
            let size: Int64?

            enum CodingKeys: String, CodingKey {
                case name
                case url = "browser_download_url"
                case size
            }
        }

        let tagName: String
        let body: String?
        let assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case assets
        }
    }
}
