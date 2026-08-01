import XCTest
@testable import ClflDesktop

/// 메뉴바 축약 코드. docs/design/ui-spec.html "조직 이름 대신 두 글자 코드를 쓴다"
///
/// 코드는 **집합에 딸린 값**이다. 겹치는지 알아야 정할 수 있으므로 이름 하나만
/// 보고는 못 만든다.
final class ShortCodeTests: XCTestCase {
    private func codes(_ names: [String]) -> [String] {
        let map = BarText.codes(for: names)
        return names.map { map[$0] ?? "?" }
    }

    /// 시안의 예. 이름 끝 숫자를 코드가 물고 간다.
    func test_specExamples() {
        XCTAssertEqual(codes(["team1", "team2"]), ["T1", "T2"])
    }

    /// 실제 이름. 시안은 알파벳순 번호를 붙이라고 하지만 이름이 이미 번호를
    /// 달고 있으면 그쪽을 쓴다. 앱 드롭다운에서 보는 것과 같아야 한다.
    func test_realNamesKeepTheirOwnNumbers() {
        XCTAssertEqual(codes(["NAVER_TEAM_40", "NAVER_TEAM_52"]), ["T40", "T52"])
    }

    /// 숫자가 없으면 앞 두 글자.
    func test_plainNameTakesTwoLetters() {
        XCTAssertEqual(codes(["Naver"]), ["Na"])
        XCTAssertEqual(codes(["Anthropic"]), ["An"])
    }

    /// 앞 두 글자가 겹치면 첫 글자에 순번을 붙인다. 순번은 알파벳순이라
    /// Nasdaq 이 1번이다.
    func test_collisionGetsAnOrdinal() {
        XCTAssertEqual(codes(["Naver", "Nasdaq"]), ["N2", "N1"])
    }

    /// 순번은 알파벳순이다. 목록에 들어온 차례가 아니다. 조직이 늘고 줄 때마다
    /// 코드가 흔들리면 눈이 못 따라간다.
    func test_ordinalFollowsAlphabet() {
        XCTAssertEqual(BarText.codes(for: ["Nasdaq", "Naver"])["Nasdaq"], "N1")
        XCTAssertEqual(BarText.codes(for: ["Naver", "Nasdaq"])["Nasdaq"], "N1")
    }

    /// 숫자가 붙은 코드끼리도 겹칠 수 있다.
    func test_numericCodesCanCollideToo() {
        let map = BarText.codes(for: ["alpha_team_1", "beta_team_1"])
        XCTAssertNotEqual(map["alpha_team_1"], map["beta_team_1"])
    }

    func test_emptyNameDoesNotCrash() {
        XCTAssertEqual(codes([""]), ["?"])
    }

    /// 코드는 좁아야 한다. 메뉴바에서 시계를 밀어내면 안 된다.
    func test_codesStayShort() {
        for c in BarText.codes(for: ["NAVER_TEAM_40", "Naver", "team1", "Anthropic"]).values {
            XCTAssertLessThanOrEqual(c.count, 3, c)
        }
    }
}
