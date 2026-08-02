import XCTest
@testable import ClflDesktop

/// 계정마다 데이터 디렉토리를 따로 둔다.
///
/// 이름에 계정 uuid 를 넣으면 어느 디렉토리가 어느 계정 것인지 경로만 보고
/// 안다. 목록을 따로 들고 다닐 필요가 없다.
final class AltDirectoryTests: XCTestCase {
    let uuid = "2a063dae-21bd-4040-ad6c-69e633ed6639"

    func test_nameCarriesTheAccount() {
        let dir = AltInstance.directory(for: uuid, home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertEqual(dir?.path, "/Users/x/.claude-alt-\(uuid)")
    }

    /// 숨김 디렉토리다. 홈에 눈에 띄게 늘어놓지 않는다.
    func test_hidden() {
        let dir = AltInstance.directory(for: uuid, home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertTrue(dir!.lastPathComponent.hasPrefix("."))
    }

    /// uuid 가 아니면 경로를 만들지 않는다. 이름이 곧 경로라서 여기가 구멍이 되면
    /// 홈 밖으로 나갈 수 있다.
    func test_rejectsAnythingButAUUID() {
        for bad in ["", "../../etc", "a/b", "2a063dae", "2a063dae-21bd-4040-ad6c-69e633ed663g",
                    "2a063dae-21bd-4040-ad6c-69e633ed6639/x"] {
            XCTAssertNil(AltInstance.directory(for: bad, home: URL(fileURLWithPath: "/Users/x")),
                         bad)
        }
    }

    func test_uuidCaseDoesNotMatter() {
        XCTAssertNotNil(AltInstance.directory(for: uuid.uppercased(),
                                              home: URL(fileURLWithPath: "/Users/x")))
    }
}

/// 어느 계정에 창이 떠 있는지 `ps -E` 출력에서 읽는다.
final class InstanceScanTests: XCTestCase {
    let sample = """
      821 /Applications/Claude.app/Contents/MacOS/Claude CLAUDE_USER_DATA_DIR=/Users/x/.claude-alt-2a063dae-21bd-4040-ad6c-69e633ed6639 PATH=/usr/bin
    28705 /Applications/Claude.app/Contents/MacOS/Claude PATH=/usr/bin HOME=/Users/x
    30011 /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=renderer
    """

    func test_findsTheAccountFromTheDirectoryName() {
        XCTAssertEqual(AltInstance.runningAccounts(psOutput: sample),
                       ["2a063dae-21bd-4040-ad6c-69e633ed6639"])
    }

    /// 기본 인스턴스는 환경변수가 없다. 별도 창으로 세지 않는다.
    func test_primaryIsNotAnAltInstance() {
        XCTAssertFalse(AltInstance.runningAccounts(psOutput: sample).contains(where: {
            $0.hasPrefix("746e81ae")
        }))
    }

    /// 헬퍼 프로세스가 수십 개 뜬다. 그걸 세면 안 된다.
    func test_ignoresHelpers() {
        XCTAssertEqual(AltInstance.runningAccounts(psOutput: sample).count, 1)
    }

    func test_emptyOutput() {
        XCTAssertTrue(AltInstance.runningAccounts(psOutput: "").isEmpty)
    }

    /// 우리 규칙과 다른 디렉토리는 무시한다. 계정을 못 알아내기 때문이다.
    func test_ignoresForeignDataDirs() {
        let odd = "  900 /Applications/Claude.app/Contents/MacOS/Claude CLAUDE_USER_DATA_DIR=/tmp/whatever"
        XCTAssertTrue(AltInstance.runningAccounts(psOutput: odd).isEmpty)
    }
}

/// 계정 하나가 어떤 상태로 보이는가.
final class InstanceSlotTests: XCTestCase {
    let a = "746e81ae-c1e7-4402-a1af-7a3cf49a7fa5"
    let b = "2a063dae-21bd-4040-ad6c-69e633ed6639"
    let c = "2b4a57bf-ecfa-49a7-9537-903301ac74b4"

    func test_primaryWins() {
        XCTAssertEqual(InstanceSlot.of(a, primary: a, running: [a], opening: []), .primary)
    }

    func test_running() {
        XCTAssertEqual(InstanceSlot.of(b, primary: a, running: [b], opening: []), .running)
    }

    func test_none() {
        XCTAssertEqual(InstanceSlot.of(c, primary: a, running: [b], opening: []), .none)
    }

    /// 245MB 를 푸느라 십수 초 걸린다. 그동안 아무 표시가 없으면 또 누른다.
    func test_openingShowsWhileItStarts() {
        XCTAssertEqual(InstanceSlot.of(c, primary: a, running: [], opening: [c]), .opening)
    }

    /// 창이 실제로 떴으면 여는 중이 아니다.
    func test_runningBeatsOpening() {
        XCTAssertEqual(InstanceSlot.of(b, primary: a, running: [b], opening: [b]), .running)
    }

    /// 누를 수 있는 것은 하나뿐이다.
    func test_onlyNoneIsActionable() {
        XCTAssertTrue(InstanceSlot.none.isActionable)
        for s in [InstanceSlot.primary, .running, .opening] {
            XCTAssertFalse(s.isActionable, "\(s)")
        }
    }

    func test_everySlotHasALabel() {
        for s in InstanceSlot.allCases { XCTAssertFalse(s.label.isEmpty, "\(s)") }
    }
}

/// 쿠키 평문 앞에 붙는 도메인 해시.
final class DomainHashTests: XCTestCase {
    /// 읽을 때 떼는 32바이트와 같은 값이어야 한다. 다르면 앱이 못 읽는다.
    func test_matchesWhatWeStrip() {
        let hash = domainHash(".claude.ai")
        XCTAssertEqual(hash.count, 32)
        // 붙였다 떼면 원래 값이다
        let value = Data("2a063dae-21bd-4040-ad6c-69e633ed6639".utf8)
        XCTAssertEqual(stripDomainHash(hash + value), value)
    }

    /// 파이썬 원형이 내는 값과 같아야 한다.
    /// python3 -c "import hashlib;print(hashlib.sha256(b'.claude.ai').hexdigest())"
    func test_knownDigest() {
        XCTAssertEqual(domainHash(".claude.ai").map { String(format: "%02x", $0) }.joined(),
                       "fcd63625da82168ee9066a8eefca57fa5845d6752b4514f434249ec35916bd60")
    }
}
