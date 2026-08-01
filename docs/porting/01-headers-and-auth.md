# 01. 헤더 위생과 인증 재작성

**출처:** `claulay/src/proxy/headers.ts` (203 LOC), `headers.test.ts`

프록시가 클라이언트 요청을 업스트림으로 넘기기 전, 그리고 업스트림 응답을 클라이언트로
되돌리기 전에 수행하는 순수 헤더 변환. 부수효과 없음.

---

## 0. 공통 타입 — 케이스 무시 헤더 백

TS 원본의 소문자 정규화 체조는 Swift에서 타입 하나로 사라진다.

```swift
struct HeaderBag {
    private(set) var storage: [String: String] = [:]   // 키는 항상 소문자

    subscript(key: String) -> String? {
        get { storage[key.lowercased()] }
        set { storage[key.lowercased()] = newValue }
    }
}
```

> **NIO 주의:** `HTTPHeaders`는 조회만 케이스 무시고 **순회 시 원본 케이싱을 보존**한다.
> `hasPrefix("anthropic-ratelimit-")` 같은 순회 기반 규칙([02](02-response-classification.md) §2-2)이
> 있으므로, 경계에서 위 타입으로 한 번 정규화하고 들어갈 것.

---

## 1. 상수

```swift
enum ProxyHeaders {
    /// 업스트림 전송 전 클라이언트 요청에서 제거.
    /// authorization/x-api-key는 vault 토큰으로 대체되므로 클라이언트 값은 오염된 것으로 간주.
    /// host는 업스트림 URL이 자체 Host를 정의. 나머지는 RFC 7230 §6.1 hop-by-hop.
    static let requestBlocklist: Set<String> = [
        "authorization", "x-api-key", "host",
        "connection", "keep-alive",
        "proxy-authenticate", "proxy-authorization", "proxy-connection",
        "te", "trailer", "transfer-encoding", "upgrade",
    ]

    /// 클라이언트로 되돌릴 때 제거. 요청 쪽과 달리 proxy-connection·host·auth 없음.
    static let responseBlocklist: Set<String> = [
        "connection", "keep-alive",
        "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade",
    ]

    /// `claude setup-token`이 발급하는 장기 OAuth 토큰 접두사.
    /// 콘솔 발급 클래식 API 키는 `sk-ant-api03-…`.
    static let oauthTokenPrefix = "sk-ant-oat01-"

    /// Anthropic이 Authorization: Bearer로 OAuth 토큰을 받기 위해 요구하는 beta 플래그.
    /// 없으면 401 "OAuth authentication is currently not supported."
    static let oauthBetaFlag = "oauth-2025-04-20"

    static let defaultAnthropicVersion = "2023-06-01"
}
```

두 blocklist의 비대칭은 원본 그대로다. 요청 쪽에만 `proxy-connection` / `host` /
인증 헤더가 있다.

---

## 2. 인증 재작성 — 최우선 규칙

```swift
extension ProxyHeaders {
    static func rewriteAuth(_ headers: HeaderBag, token: String) -> HeaderBag {
        var out = headers

        // 클래식 API 키 분기: anthropic-beta는 건드리지 않는다.
        guard token.hasPrefix(oauthTokenPrefix) else {
            out["x-api-key"] = token
            return out
        }

        // OAuth 장기 토큰 분기:
        // Authorization: Bearer 와 anthropic-beta의 oauth 플래그가 "둘 다" 필요.
        let existingBeta = out["anthropic-beta"]
        out["authorization"]  = "Bearer \(token)"
        out["anthropic-beta"] = mergeBetaFlag(existing: existingBeta, flag: oauthBetaFlag)
        return out
    }

    /// 기존 값 순서를 보존하며 플래그를 병합. 이미 있으면 중복 추가하지 않음(멱등).
    static func mergeBetaFlag(existing: String?, flag: String) -> String {
        guard let existing, !existing.isEmpty else { return flag }
        var parts = existing.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !parts.contains(flag) { parts.append(flag) }
        return parts.joined(separator: ", ")
    }
}
```

### 왜 이게 1순위인가

`headers.ts:88-95`의 주석은 실전 장애 기록이다.

**OAuth 토큰을 `x-api-key`로 보내면:**

```
401 "invalid x-api-key"
  → 스왑 로직이 authentication_error로 분류
  → 모든 계정이 차례로 invalid 처리
  → 체인이 즉시 소진
```

증상이 "전 계정 인증 실패"로 나타나 원인 추적이 매우 어렵다.

**beta 플래그가 없으면:**

```
401 "OAuth authentication is currently not supported."
```

**덮어쓰기가 아니라 병합이어야 하는 이유:** Claude Code가 `claude-code-20250219` 같은
자체 플래그를 이미 보내고 있다. 덮어쓰면 해당 기능이 소실된다.

호출 측은 `rewriteAuth` 전에 `stripClientHopByHop`으로 인바운드 `authorization` /
`x-api-key`를 이미 제거했어야 한다.

---

## 3. 나머지 요청 측 변환

```swift
extension ProxyHeaders {
    static func stripClientHopByHop(_ headers: HeaderBag) -> HeaderBag {
        var out = HeaderBag()
        for (k, v) in headers.storage where !requestBlocklist.contains(k) {
            out[k] = v
        }
        return out
    }

    /// 클라이언트가 보낸 값이 있으면 그대로 보존하고, 없을 때만 기본값 주입.
    static func injectAnthropicVersion(
        _ headers: HeaderBag,
        default version: String = defaultAnthropicVersion
    ) -> HeaderBag {
        var out = headers
        if out["anthropic-version"] == nil { out["anthropic-version"] = version }
        return out
    }
}
```

**적용 순서는 고정이다:**

```
stripClientHopByHop → rewriteAuth → injectAnthropicVersion
```

---

## 4. URL 조립

```swift
extension ProxyHeaders {
    /// ⚠️ URLComponents / URL(string:) 를 쓰지 말 것.
    /// 정규화가 enterprise gateway의 path prefix(`/anthropic` 등)를 망가뜨리고
    /// query string을 재인코딩한다. 문자열 결합이 의도된 구현.
    static func buildUpstreamURL(baseURL: String, requestURI: String) -> String {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let path = requestURI.hasPrefix("/") ? requestURI : "/" + requestURI
        return base + path
    }
}
```

처리 대상: base_url 후행 슬래시, query string 원문 보존, 기업용 게이트웨이의 경로 접두사.

---

## 5. 응답 헤더 — 원본을 그대로 베끼면 안 되는 유일한 항목

```swift
extension ProxyHeaders {
    static func pickResponseHeaders(
        _ upstream: HeaderBag,
        clientDecodedBody: Bool
    ) -> HeaderBag {
        var out = HeaderBag()
        for (k, v) in upstream.storage {
            if responseBlocklist.contains(k) { continue }
            if k == "content-length" { continue }             // 프레이밍은 우리가 소유
            if k == "content-encoding" && clientDecodedBody { continue }
            out[k] = v
        }
        return out
    }
}
```

**`content-length`:** 우리가 재청킹하거나 업스트림이 chunked였을 때 잘못된 신호가 되므로
항상 제거. 서버 응답 객체가 프레이밍을 소유한다.

**`content-encoding`:** 원본이 무조건 제거하는 것은 **Node의 `fetch`가 gzip/br을 투명하게
해제해서 평문 body를 주기 때문**이다. 헤더만 남기면 클라이언트가 두 번째 해제를 시도해
`ZlibError`가 난다.

Swift에서는 HTTP 클라이언트에 따라 갈린다:

| 클라이언트 | 자동 해제 | `content-encoding` |
|---|---|---|
| `URLSession` | 함 | **제거** (`clientDecodedBody = true`) |
| `AsyncHTTPClient` / raw NIO 릴레이 | 안 함 | **유지** (`clientDecodedBody = false`) |

스트리밍 패스스루를 NIO로 짜면 후자일 가능성이 높다. 잘못 제거하면 클라이언트가
압축 바이트를 평문으로 파싱한다.

---

## 6. 함정 요약

| # | 함정 | 증상 |
|---|---|---|
| 1 | OAuth 토큰을 `x-api-key`로 전송 | 전 계정 invalid, 체인 즉시 소진 |
| 2 | `anthropic-beta`에 oauth 플래그 누락 | `401 "OAuth authentication is currently not supported."` |
| 3 | `anthropic-beta`를 병합 대신 덮어쓰기 | Claude Code 기능 소실 |
| 4 | `content-encoding`을 무조건 제거 | NIO raw 릴레이 시 클라이언트가 압축 바이트를 평문 파싱 |
| 5 | URL 조립에 `URLComponents` | enterprise gateway path prefix·query 손상 |

---

## 7. 테스트 케이스

`headers.test.ts`에서 그대로 옮길 것.

### `stripClientHopByHop`
- `authorization` / `x-api-key` / `host` / hop-by-hop 메타데이터를 제거한다
- 모든 헤더 키를 소문자화한다

### `rewriteAuth` — 클래식 API 키 분기
- vault 토큰을 `x-api-key`로 설정한다
- 입력 객체를 변경하지 않는다 (fresh record 반환)
- **`anthropic-beta`를 건드리지 않는다**

### `rewriteAuth` — OAuth 분기 (함정 1·2·3을 잠그는 회귀 테스트)
- 클라이언트 beta가 없을 때 `Authorization: Bearer` + oauth 플래그를 설정한다
- 기존 `anthropic-beta`에 `oauth-2025-04-20`을 **중복 없이 병합**한다
- 클라이언트가 이미 `oauth-2025-04-20`을 보냈으면 **멱등**하다
- 대소문자가 섞인 `anthropic-beta` 키를 정규 소문자 키로 정규화한다
- 입력 객체를 변경하지 않는다

### `injectAnthropicVersion`
- 클라이언트가 보내지 않았을 때 추가한다
- 클라이언트가 보낸 값을 **원문 그대로 보존**한다
- 클라이언트 값 탐지가 대소문자 무시다

### `buildUpstreamURL`
- base_url과 path+query를 결합한다
- base_url의 후행 슬래시를 멱등하게 처리한다
- query string을 원문 그대로 보존한다
- 경로 접두사가 있는 enterprise gateway를 지원한다

### `pickResponseHeaders`
- hop-by-hop 응답 헤더와 `content-length`를 제거하고 키를 소문자화한다
- **(추가)** `clientDecodedBody = false`일 때 `content-encoding`을 **유지**한다 ← Swift 전용
