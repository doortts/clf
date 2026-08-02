import XCTest
@testable import ClflDesktop

/// 계정마다 데이터 디렉토리를 따로 둔다.
///
/// 이름에 계정 이름을 넣으면 어느 디렉토리가 어느 계정 것인지 경로만 보고
/// 안다. 목록을 따로 들고 다닐 필요가 없다.
final class AltDirectoryTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/x")

    func test_nameCarriesTheAccount() {
        XCTAssertEqual(AltInstance.directory(for: "NAVER_TEAM_52", home: home)?.path,
                       "/Users/x/.claude-alt-NAVER_TEAM_52")
    }

    /// 공백을 뺀다. 경로에 공백이 있으면 셸에서도 로그에서도 성가시다.
    func test_spacesAreRemoved() {
        XCTAssertEqual(AltInstance.slug("My Team 1"), "MyTeam1")
        XCTAssertEqual(AltInstance.directory(for: "My Team 1", home: home)?.lastPathComponent,
                       ".claude-alt-MyTeam1")
    }

    /// 숨김 디렉토리다. 홈에 눈에 띄게 늘어놓지 않는다.
    func test_hidden() {
        XCTAssertTrue(AltInstance.directory(for: "Naver", home: home)!
            .lastPathComponent.hasPrefix("."))
    }

    /// **이름이 곧 경로다.** 여기가 구멍이 되면 홈 밖으로 나간다.
    func test_pathEscapesAreBlocked() {
        for bad in ["", "   ", "..", "../..", "/", "."] {
            XCTAssertNil(AltInstance.slug(bad), bad)
        }
        // 구분자는 지운다. 이름이 한 조각으로 남아야 한다
        XCTAssertEqual(AltInstance.slug("a/b"), "a-b")
        XCTAssertEqual(AltInstance.slug("../etc"), "etc")
        for name in ["a/b", "../etc", "x:y"] {
            XCTAssertEqual(AltInstance.directory(for: name, home: home)?
                .deletingLastPathComponent().path, "/Users/x", name)
        }
    }

    /// 한글 이름도 그대로 쓴다. 경로에 문제없는 글자다.
    func test_hangulSurvives() {
        XCTAssertEqual(AltInstance.slug("네이버 팀"), "네이버팀")
    }

    /// 우리가 만든 디렉토리인지 경로로 판정한다. 지울 때 이걸 쓴다.
    func test_recognizesOurOwn() {
        XCTAssertTrue(AltInstance.isOurs(home.appendingPathComponent(".claude-alt-Naver")))
        XCTAssertFalse(AltInstance.isOurs(home.appendingPathComponent(".claude")))
        XCTAssertFalse(AltInstance.isOurs(home.appendingPathComponent("Documents")))
        XCTAssertFalse(AltInstance.isOurs(home.appendingPathComponent(".claude-alt")))
    }
}

/// 어느 계정에 창이 떠 있는지 `ps -A -E` 출력에서 읽는다.
final class InstanceScanTests: XCTestCase {
    let sample = """
    /Applications/Claude.app/Contents/MacOS/Claude CLAUDE_USER_DATA_DIR=/Users/x/.claude-alt-NAVER_TEAM_52 PATH=/usr/bin
    /Applications/Claude.app/Contents/MacOS/Claude PATH=/usr/bin HOME=/Users/x
    /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=renderer
    """

    func test_findsTheAccountFromTheDirectoryName() {
        XCTAssertEqual(AltInstance.runningAccounts(psOutput: sample), ["NAVER_TEAM_52"])
    }

    /// 기본 인스턴스는 환경변수가 없고 헬퍼는 실행 파일이 다르다. 둘 다 안 센다.
    func test_countsOnlyOurInstances() {
        XCTAssertEqual(AltInstance.runningAccounts(psOutput: sample).count, 1)
    }

    func test_emptyOutput() {
        XCTAssertTrue(AltInstance.runningAccounts(psOutput: "").isEmpty)
    }

    /// 우리 규칙과 다른 디렉토리는 무시한다. 계정을 못 알아내기 때문이다.
    func test_ignoresForeignDataDirs() {
        let odd = "/Applications/Claude.app/Contents/MacOS/Claude CLAUDE_USER_DATA_DIR=/tmp/whatever"
        XCTAssertTrue(AltInstance.runningAccounts(psOutput: odd).isEmpty)
    }
}

/// 계정 하나가 어떤 상태로 보이는가.
final class InstanceSlotTests: XCTestCase {

    func test_primaryWins() {
        XCTAssertEqual(InstanceSlot.of(slug: "T40", isPrimary: true,
                                       running: ["T40"], opening: []), .primary)
    }

    func test_running() {
        XCTAssertEqual(InstanceSlot.of(slug: "T52", isPrimary: false,
                                       running: ["T52"], opening: []), .running)
    }

    func test_none() {
        XCTAssertEqual(InstanceSlot.of(slug: "Nav", isPrimary: false,
                                       running: ["T52"], opening: []), .none)
    }

    /// 245MB 를 푸느라 십수 초 걸린다. 그동안 아무 표시가 없으면 또 누른다.
    func test_openingShowsWhileItStarts() {
        XCTAssertEqual(InstanceSlot.of(slug: "Nav", isPrimary: false,
                                       running: [], opening: ["Nav"]), .opening)
    }

    // MARK: 상태와 동작을 가른다. HIG 는 단추 라벨을 동사로 쓰라고 한다.
    // docs/design/popover-hig-mockup.html

    /// 창이 떠 있는 것은 상태 배지, 앞으로 꺼내는 것은 단추다.
    func test_runningSplitsStateAndAction() {
        XCTAssertEqual(InstanceSlot.running.badgeLabel, "창 열려있음")
        XCTAssertEqual(InstanceSlot.running.actionLabel, "앞으로 꺼내기")
    }

    func test_launchIsAnActionWithoutState() {
        XCTAssertNil(InstanceSlot.none.badgeLabel)
        XCTAssertEqual(InstanceSlot.none.actionLabel, "새 창 띄우기")
    }

    /// 기본, 여는 중, 못 띄움은 상태뿐이다. 누를 것이 없다.
    func test_pureStatesHaveNoAction() {
        for slot in [InstanceSlot.primary, .opening, .unavailable] {
            XCTAssertNil(slot.actionLabel, "\(slot)")
            XCTAssertNil(slot.badgeLabel, "\(slot)")
        }
    }

    /// 창이 실제로 떴으면 여는 중이 아니다.
    func test_runningBeatsOpening() {
        XCTAssertEqual(InstanceSlot.of(slug: "T52", isPrimary: false,
                                       running: ["T52"], opening: ["T52"]), .running)
    }

    /// 이름에서 경로를 못 만들면 띄울 수도 없다.
    func test_unusableNameCannotLaunch() {
        XCTAssertEqual(InstanceSlot.of(slug: nil, isPrimary: false,
                                       running: [], opening: []), .unavailable)
    }

    /// 누를 수 있는 것은 하나뿐이다.
    func test_onlyNoneIsActionable() {
        XCTAssertTrue(InstanceSlot.none.isActionable)
        for s in [InstanceSlot.primary, .running, .opening, .unavailable] {
            XCTAssertFalse(s.isActionable, "\(s)")
        }
    }

    func test_everySlotHasALabel() {
        for s in InstanceSlot.allCases { XCTAssertFalse(s.label.isEmpty, "\(s)") }
    }
}

/// 쿠키 평문 앞에 붙는 도메인 해시.
final class DomainHashTests: XCTestCase {
    func test_matchesWhatWeStrip() {
        let hash = domainHash(".claude.ai")
        XCTAssertEqual(hash.count, 32)
        let value = Data("2a063dae-21bd-4040-ad6c-69e633ed6639".utf8)
        XCTAssertEqual(stripDomainHash(hash + value), value)
    }

    /// python3 -c "import hashlib;print(hashlib.sha256(b'.claude.ai').hexdigest())"
    func test_knownDigest() {
        XCTAssertEqual(domainHash(".claude.ai").map { String(format: "%02x", $0) }.joined(),
                       "fcd63625da82168ee9066a8eefca57fa5845d6752b4514f434249ec35916bd60")
    }
}

/// 창을 앞으로 꺼내려면 pid 가 있어야 한다.
final class InstancePIDTests: XCTestCase {
    let sample = """
      821 /Applications/Claude.app/Contents/MacOS/Claude CLAUDE_USER_DATA_DIR=/Users/x/.claude-alt-NAVER_TEAM_52 PATH=/usr/bin
      950 /Applications/Claude.app/Contents/MacOS/Claude CLAUDE_USER_DATA_DIR=/Users/x/.claude-alt-Naver PATH=/usr/bin
    28705 /Applications/Claude.app/Contents/MacOS/Claude PATH=/usr/bin
    30011 /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=renderer
    """

    func test_mapsAccountToPID() {
        let found = AltInstance.runningInstances(psOutput: sample)
        XCTAssertEqual(found["NAVER_TEAM_52"], 821)
        XCTAssertEqual(found["Naver"], 950)
        XCTAssertEqual(found.count, 2)
    }

    /// 계정 목록은 그 지도의 열쇠다. 두 값이 어긋나면 안 된다.
    func test_accountsMatchTheMap() {
        XCTAssertEqual(AltInstance.runningAccounts(psOutput: sample),
                       Set(AltInstance.runningInstances(psOutput: sample).keys))
    }

    /// pid 가 없는 줄은 버린다. 앞에 pid 가 붙어 나오지 않는 형식일 수 있다.
    func test_ignoresLinesWithoutAPID() {
        let noPID = "/Applications/Claude.app/Contents/MacOS/Claude CLAUDE_USER_DATA_DIR=/Users/x/.claude-alt-A"
        XCTAssertTrue(AltInstance.runningInstances(psOutput: noPID).isEmpty)
    }
}

/// 배지는 눈길을 끄는 자리다. 평상시에 켜 두면 정작 급한 것이 묻힌다.
final class BandBadgeTests: XCTestCase {
    func test_onlyLowAndEmptySpeak() {
        XCTAssertTrue(UsageBand.empty.isNoteworthy)
        XCTAssertTrue(UsageBand.low.isNoteworthy)
    }

    /// 여유는 게이지 길이와 초록색으로 이미 보인다.
    func test_ampleAndNormalStaySilent() {
        XCTAssertFalse(UsageBand.ample.isNoteworthy)
        XCTAssertFalse(UsageBand.normal.isNoteworthy)
    }
}
