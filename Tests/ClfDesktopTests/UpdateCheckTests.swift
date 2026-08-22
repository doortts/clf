import XCTest
@testable import ClfDesktop

/// 태그 문자열을 버전으로 읽는다.
///
/// 릴리즈 버전만 받는다. 태그 위가 아닌 빌드에서 확인을 건너뛰는 것이 이
/// 파싱 실패의 일이다. docs/design/14-self-update.html 2절
final class ReleaseVersionTests: XCTestCase {

    /// **문자열 비교면 여기서 깨진다.** 자리별로 견뎌야 한다.
    func test_comparesNumericallyNotLexically() {
        let ten = ReleaseVersion.release(from: "0.10.0")!
        let nine = ReleaseVersion.release(from: "0.9.0")!
        XCTAssertGreaterThan(ten, nine)
        XCTAssertLessThan(nine, ten)
    }

    func test_vPrefixIsOptional() {
        XCTAssertEqual(ReleaseVersion.release(from: "v0.4.0"),
                       ReleaseVersion.release(from: "0.4.0"))
        XCTAssertEqual(ReleaseVersion.release(from: "V0.4.0"),
                       ReleaseVersion.release(from: "0.4.0"))
    }

    func test_comparesEveryPosition() {
        func v(_ s: String) -> ReleaseVersion { ReleaseVersion.release(from: s)! }
        XCTAssertGreaterThan(v("1.0.0"), v("0.99.99"))
        XCTAssertGreaterThan(v("0.5.1"), v("0.5.0"))
        XCTAssertEqual(v("0.5.0"), v("v0.5.0"))
    }

    /// 태그 뒤 커밋이 붙은 빌드는 릴리즈가 아니다. 확인 자체를 건너뛴다.
    func test_describeOutputIsNotARelease() {
        XCTAssertNil(ReleaseVersion.release(from: "0.4.0-3-gabc123"))
        XCTAssertNil(ReleaseVersion.release(from: "v0.4.0-3-gabc123"))
        XCTAssertNil(ReleaseVersion.release(from: "v0.4.0-dirty"))
    }

    /// 태그가 하나도 없으면 `git describe --always` 가 커밋 해시를 준다.
    func test_hashesAndJunkAreNotVersions() {
        for raw in ["abc1234", "dev", "", "  ", "0.4", "0.4.0.1", "v", "x.y.z", "-1.2.3"] {
            XCTAssertNil(ReleaseVersion.release(from: raw), "\(raw) 는 버전이 아니다")
        }
    }

    /// 앞뒤 공백은 흘려도 된다. 안에 든 것은 아니다.
    func test_trimsSurroundingWhitespace() {
        XCTAssertEqual(ReleaseVersion.release(from: " v1.2.3\n"),
                       ReleaseVersion(major: 1, minor: 2, patch: 3))
        XCTAssertNil(ReleaseVersion.release(from: "1. 2.3"))
    }

    func test_descriptionRoundTrips() {
        XCTAssertEqual(ReleaseVersion(major: 0, minor: 5, patch: 0).description, "v0.5.0")
    }
}

/// 릴리즈 JSON 하나를 읽고 받을 자산을 고른다.
final class ReleaseDecodeTests: XCTestCase {

    private func json(assets: String, tag: String = "v0.5.0",
                      body: String = "- 첫 줄") -> Data {
        Data("""
        {"tag_name": "\(tag)", "body": "\(body)", "assets": [\(assets)]}
        """.utf8)
    }

    private func asset(_ name: String, size: Int = 4_400_000) -> String {
        """
        {"name": "\(name)", "size": \(size),
         "browser_download_url": "https://example.test/\(name)"}
        """
    }

    /// 확장자가 중간에 든 것이 걸리면 받아 놓고 마운트에서 실패한다.
    func test_picksTheDMGAndNotItsChecksum() {
        let data = json(assets: [asset("clf-v0.5.0.dmg.sha256"),
                                 asset("clf-v0.5.0.dmg")].joined(separator: ","))
        let release = UpdateCheck.decode(data)
        XCTAssertEqual(release?.dmg?.lastPathComponent, "clf-v0.5.0.dmg")
    }

    func test_readsTagAndSize() {
        let release = UpdateCheck.decode(json(assets: asset("clf-v0.5.0.dmg", size: 4_400_000)))
        XCTAssertEqual(release?.tag, "v0.5.0")
        XCTAssertEqual(release?.version, ReleaseVersion(major: 0, minor: 5, patch: 0))
        XCTAssertEqual(release?.bytes, 4_400_000)
    }

    /// 자산이 하나도 안 맞으면 nil 이고 **오류가 아니다.** 릴리즈 페이지로
    /// 보내면 된다.
    func test_missingAssetIsNotAnError() {
        let release = UpdateCheck.decode(json(assets: asset("clf-v0.5.0.zip")))
        XCTAssertNotNil(release)
        XCTAssertNil(release?.dmg)
    }

    func test_emptyAssetListDecodes() {
        XCTAssertNotNil(UpdateCheck.decode(json(assets: "")))
    }

    func test_garbageDoesNotDecode() {
        XCTAssertNil(UpdateCheck.decode(Data("not json".utf8)))
        XCTAssertNil(UpdateCheck.decode(Data(#"{"body":"태그가 없다"}"#.utf8)))
    }

    /// 대문자 확장자도 DMG 다.
    func test_extensionMatchIsCaseInsensitive() {
        let release = UpdateCheck.decode(json(assets: asset("clf-v0.5.0.DMG")))
        XCTAssertNotNil(release?.dmg)
    }

    func test_noteLinesSkipEmptiesAndCutAtLimit() {
        let release = Release(tag: "v0.5.0", notes: "\n- 하나\n\n- 둘\n- 셋\n- 넷\n")
        XCTAssertEqual(release.noteLines(), ["- 하나", "- 둘", "- 셋"])
    }

    func test_sizeTextIsNilWithoutSize() {
        XCTAssertNil(Release(tag: "v0.5.0").sizeText)
        XCTAssertEqual(Release(tag: "v0.5.0", bytes: 4_404_019).sizeText, "4.2MB")
    }
}

/// 응답 코드마다 뜻이 다르다.
final class ReleaseFetchTests: XCTestCase {

    /// **404 는 오류가 아니다.** 릴리즈가 하나도 없을 때 GitHub 이 주는 답이고,
    /// 첫 릴리즈가 올라가기 전까지 모든 사용자가 이것을 받는다. 여기서 오류를
    /// 띄우면 전원이 빨간 줄을 본다. docs/design/17-repo-split.html 2절
    func test_notFoundMeansNoReleaseYet() {
        XCTAssertEqual(UpdateCheck.classify(status: 404, body: nil), .none)
    }

    func test_notModifiedIsItsOwnAnswer() {
        XCTAssertEqual(UpdateCheck.classify(status: 304, body: nil), .notModified)
    }

    func test_okNeedsAReadableBody() {
        guard case .failed = UpdateCheck.classify(status: 200, body: Data("x".utf8)) else {
            return XCTFail("못 읽은 본문은 실패로 떨어져야 한다")
        }
        guard case .failed = UpdateCheck.classify(status: 200, body: nil) else {
            return XCTFail("본문이 없으면 실패다")
        }
    }

    func test_rateLimitAndServerErrorsSayWhy() {
        for status in [401, 403, 500, 503, 418] {
            guard case .failed(let why) = UpdateCheck.classify(status: status, body: nil) else {
                return XCTFail("\(status) 는 실패다")
            }
            // 사용자가 읽을 문장이다. 코드만 던지면 할 수 있는 일이 없다
            XCTAssertTrue(why.contains("\(status)"), "\(why) 에 코드가 있어야 한다")
        }
    }
}

/// 24시간 규칙과 개발 빌드 판정.
final class UpdateEligibilityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func test_firstRunAlwaysChecks() {
        XCTAssertTrue(UpdateCheck.shouldCheck(last: nil, now: now))
    }

    func test_waitsAFullDay() {
        let hours: (Double) -> Date = { self.now.addingTimeInterval(-$0 * 3600) }
        XCTAssertFalse(UpdateCheck.shouldCheck(last: hours(23), now: now))
        XCTAssertTrue(UpdateCheck.shouldCheck(last: hours(25), now: now))
    }

    /// 시계가 뒤로 간 기계가 영영 확인을 안 하면 안 된다. 미래 도장은 못 믿는다.
    func test_futureStampIsNotTrusted() {
        XCTAssertTrue(UpdateCheck.shouldCheck(last: now.addingTimeInterval(3600), now: now))
    }

    /// 팝오버를 열 때는 한 시간이다. 여닫기가 잦아서 바닥이 없으면 몇 초 사이에
    /// 요청이 여러 번 나간다.
    func test_openingUsesTheHourlyFloor() {
        let minutes: (Double) -> Date = { self.now.addingTimeInterval(-$0 * 60) }
        let floor = UpdateCheck.openInterval
        XCTAssertFalse(UpdateCheck.shouldCheck(last: minutes(1), now: now, interval: floor))
        XCTAssertFalse(UpdateCheck.shouldCheck(last: minutes(59), now: now, interval: floor))
        XCTAssertTrue(UpdateCheck.shouldCheck(last: minutes(61), now: now, interval: floor))
    }

    /// 같은 도장을 두 바닥이 본다. 두 시간 전이면 팝오버는 보고 주기는 안 본다.
    func test_theSameStampMeansDifferentThingsToTheTwoFloors() {
        let twoHoursAgo = now.addingTimeInterval(-2 * 3600)
        XCTAssertTrue(UpdateCheck.shouldCheck(last: twoHoursAgo, now: now,
                                              interval: UpdateCheck.openInterval))
        XCTAssertFalse(UpdateCheck.shouldCheck(last: twoHoursAgo, now: now))
    }

    /// 저장소에서 바로 실행한 것이다. 릴리즈로 갈아타면 방금 빌드한 것이 사라진다.
    func test_buildDirectoryIsADevelopmentBuild() {
        let verdict = UpdateCheck.eligibility(
            version: "v0.4.0", bundlePath: "/Users/me/repos/clf/.build/clf.app")
        guard case .developmentBuild(let why) = verdict else {
            return XCTFail("저장소 안 번들은 개발 빌드다")
        }
        XCTAssertFalse(why.isEmpty)
    }

    func test_untaggedBuildIsADevelopmentBuild() {
        let verdict = UpdateCheck.eligibility(
            version: "abc1234", bundlePath: "/Users/me/Applications/clf.app")
        guard case .developmentBuild(let why) = verdict else {
            return XCTFail("태그 없는 빌드는 개발 빌드다")
        }
        // 왜 확인을 안 하는지 설정에 적을 수 있어야 한다
        XCTAssertTrue(why.contains("abc1234"))
    }

    func test_taggedBuildInApplicationsIsEligible() {
        let verdict = UpdateCheck.eligibility(
            version: "v0.4.0", bundlePath: "/Users/me/Applications/clf.app")
        guard case .eligible(let version) = verdict else {
            return XCTFail("태그 빌드는 확인 대상이다")
        }
        XCTAssertEqual(version, ReleaseVersion(major: 0, minor: 4, patch: 0))
    }
}
