import Foundation

/// 지저분한 입력에서 자격증명 하나를 찾아낸다.
///
/// `claude setup-token` 은 파이프로 넘겨도 ANSI 제어 문자와 화면 다시 그리기를
/// 그대로 뿜는다. 사용자가 grep 파이프라인을 만들 것이 아니라 도구가 뽑아내야 한다.
///
/// **값을 고치지 않는다. 찾아낼 뿐이다.** 후보가 정확히 하나일 때만 통과시키고,
/// 없거나 둘 이상이면 거부한다. 자격증명을 우리가 짐작해서 고르면 안 된다.
public struct TokenExtraction: Sendable {
    public let text: String
    /// 원문 그대로가 아니라 뽑아낸 것이면 true. 호출자가 그 사실을 알린다.
    public let wasCleaned: Bool
}

/// 이보다 짧으면 잘린 것으로 본다.
///
/// 터미널 접힘으로 토큰 한가운데 줄바꿈이 들어가면 앞 조각만 뽑힌다. 그걸
/// 저장하면 401 을 맞고 사용자는 이유를 모른다. 길이로 걸러 미리 말한다.
let minimumTokenLength = 40

public func extractToken(from raw: String) throws -> TokenExtraction {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw TokenHygieneError(description: "입력이 비었다. 토큰을 파이프로 넣는다")
    }

    // 이미 깨끗하면 손대지 않는다. 다만 검사는 깨끗한 값에도 건다.
    // 잘린 토큰이나 덜 캡처된 블록은 어떤 경로로 왔든 잘못된 값이다
    if (try? validateTokenText(trimmed)) != nil {
        if trimmed.hasPrefix("{") {
            guard OAuthCredential(claudeAiOauthJSON: Data(trimmed.utf8)) != nil else {
                throw TokenHygieneError(description: incompleteBlock)
            }
        } else {
            try checkLength(trimmed)
        }
        return TokenExtraction(text: trimmed, wasCleaned: false)
    }

    let cleaned = stripControlSequences(trimmed)

    if let json = extractOAuthBlock(cleaned) {
        return TokenExtraction(text: json, wasCleaned: true)
    }

    let candidates = findTokens(cleaned)
    switch candidates.count {
    case 1:
        try checkLength(candidates[0])
        return TokenExtraction(text: candidates[0], wasCleaned: true)

    case 0:
        throw TokenHygieneError(description: cleaned.contains("claudeAiOauth")
            ? incompleteBlock
            : """
              입력에서 토큰을 찾지 못했다. sk-ant- 로 시작하는 값이나
              {"claudeAiOauth": ...} 블록이 있어야 한다.
              """)

    default:
        throw TokenHygieneError(description: """
        서로 다른 토큰이 \(candidates.count)개 있다. 어느 것인지 우리가 고를 수 없다.
        쓸 토큰 하나만 남겨 다시 넣는다.
        """)
    }
}

private let incompleteBlock = """
    claudeAiOauth 블록에 accessToken, refreshToken, expiresAt 이 모두 있어야 한다.
    캡처가 덜 됐을 수 있다. 블록 전체를 다시 넣는다.
    """

/// JSON 블록은 길이를 재지 않는다. 자체 구조로 이미 검증된다.
private func checkLength(_ token: String) throws {
    guard !token.hasPrefix("{"), token.count < minimumTokenLength else { return }
    throw TokenHygieneError(description: """
    토큰이 \(token.count)글자로 너무 짧다. 터미널에서 접히며 잘렸을 수 있다.
    파일로 받아 넘기면 접힘을 피할 수 있다:
      claude setup-token > /tmp/tok.txt
      clflctl accounts add <id> < /tmp/tok.txt
    """)
}

/// ANSI 제어 시퀀스와 커서 이동을 걷어낸다.
///
/// CSI(`ESC [ ... 종결자`), OSC(`ESC ] ... BEL` 또는 `ESC \`), 그 밖의 두 글자
/// 이스케이프를 모두 지운다. 남은 제어 문자는 공백으로 바꿔 토큰끼리 붙지 않게 한다.
func stripControlSequences(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    let scalars = Array(text.unicodeScalars)
    var i = 0

    while i < scalars.count {
        let scalar = scalars[i]
        guard scalar.value == 0x1B else {
            // 남은 제어 문자는 경계로 본다. 지워버리면 앞뒤 조각이 붙어
            // 없던 토큰이 만들어진다
            out.append(scalar.value < 0x20 || scalar.value == 0x7F ? " " : scalar)
            i += 1
            continue
        }

        i += 1
        guard i < scalars.count else { break }
        switch scalars[i] {
        case "[":                                   // CSI. 종결자는 0x40-0x7E
            i += 1
            while i < scalars.count, !(0x40...0x7E).contains(scalars[i].value) { i += 1 }
            if i < scalars.count { i += 1 }
        case "]":                                   // OSC. BEL 이나 ESC \ 로 끝난다
            i += 1
            while i < scalars.count {
                if scalars[i].value == 0x07 { i += 1; break }
                if scalars[i].value == 0x1B, i + 1 < scalars.count, scalars[i + 1] == "\\" {
                    i += 2
                    break
                }
                i += 1
            }
        default:
            i += 1
        }
        out.append(" ")                             // 지운 자리를 경계로 남긴다
    }
    return String(out)
}

/// `sk-ant-` 로 시작하는 토큰 후보. 중복은 하나로 본다.
///
/// 화면을 여러 번 다시 그린 출력에는 같은 토큰이 반복해서 나온다.
func findTokens(_ text: String) -> [String] {
    var found: [String] = []
    var seen = Set<String>()

    // 토큰 문자 집합. URL-safe base64 에 하이픈이 섞인 모양이다
    func isTokenScalar(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("A"..."Z").contains(s)
            || ("0"..."9").contains(s) || s == "-" || s == "_"
    }

    let scalars = Array(text.unicodeScalars)
    var i = 0
    while i < scalars.count {
        guard isTokenScalar(scalars[i]) else { i += 1; continue }
        var j = i
        while j < scalars.count, isTokenScalar(scalars[j]) { j += 1 }

        let run = String(String.UnicodeScalarView(scalars[i..<j]))
        if run.hasPrefix("sk-ant-"), seen.insert(run).inserted { found.append(run) }
        i = j
    }
    return found
}

/// `{"claudeAiOauth": ...}` 블록을 균형 잡힌 중괄호까지 잘라낸다.
func extractOAuthBlock(_ text: String) -> String? {
    guard let start = text.range(of: "{") else { return nil }

    var depth = 0
    var inString = false
    var escaped = false
    var index = start.lowerBound

    while index < text.endIndex {
        let character = text[index]
        if escaped {
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if character == "\"" {
            inString.toggle()
        } else if !inString {
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    let block = String(text[start.lowerBound...index])
                    // 자격증명 블록인지 확인한다. 아무 JSON 이나 받으면 안 된다
                    return OAuthCredential(claudeAiOauthJSON: Data(block.utf8)) != nil
                        ? block : nil
                }
            }
        }
        index = text.index(after: index)
    }
    return nil
}
