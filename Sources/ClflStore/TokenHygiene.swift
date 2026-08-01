import Foundation

/// 붙여넣기 오염을 등록 시점에 막는다.
///
/// 터미널에서 토큰을 복사하면 프롬프트 장식(Powerline, Nerd Font 글리프)이나
/// 줄바꿈이 함께 딸려온다. 그대로 저장하면 업스트림이 401 을 내고 사용자는
/// 토큰이 틀렸다고 생각한다. 실제로 겪은 경로다.
public struct TokenHygieneError: Error, CustomStringConvertible {
    public let description: String
}

/// 통과시키는 것은 출력 가능한 ASCII 뿐이다.
///
/// setup-token 은 URL-safe base64 문자 집합이고 oauth 캡처는 JSON 이다.
/// 둘 다 이 범위 안에 있다. JSON 안의 공백은 허용하되 토큰 안의 공백은 막아야
/// 하므로, `{` 로 시작하면 JSON 으로 보고 공백만 봐준다.
public func validateTokenText(_ text: String) throws {
    guard !text.isEmpty else {
        throw TokenHygieneError(description: "입력이 비었다. 토큰을 파이프로 넣는다")
    }
    let isJSON = text.hasPrefix("{")

    for (offset, scalar) in text.unicodeScalars.enumerated() {
        let position = offset + 1
        switch scalar.value {
        case 0x20:
            if isJSON { continue }
            throw TokenHygieneError(description: describe(
                "공백이 \(position)번째에 있다", text: text))
        case 0x09, 0x0A, 0x0D:
            throw TokenHygieneError(description: describe(
                "줄바꿈이나 탭이 \(position)번째에 있다", text: text))
        case 0x21...0x7E:
            continue
        default:
            throw TokenHygieneError(description: describe(
                String(format: "U+%04X 가 %d번째에 있다", scalar.value, position),
                text: text))
        }
    }
}

/// 무엇이 잘못됐는지와 어떻게 고치는지를 함께 말한다.
private func describe(_ what: String, text: String) -> String {
    """
    붙여넣기에 토큰이 아닌 문자가 섞였다. \(what)
    터미널에서 복사하면 프롬프트 장식이나 줄바꿈이 함께 딸려온다.
    토큰만 다시 복사하거나 파일로 넘긴다:
      claude setup-token | tail -1 | clflctl accounts add <id>
    """
}
