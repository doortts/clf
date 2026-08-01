# 03. SSE peek와 스트리밍 패스스루

**출처:** `claulay/src/proxy/stream-peek.ts` (274), `sse-parser.ts` (141),
`stream-writer.ts` (330), `upstream-attempt.ts` (269), 각 `.test.ts`

**NIO/Swift concurrency로 오면 가장 많이 달라지는 부분이다.** claulay가 이 영역에 쓴
~860 LOC 중 상당량은 Web Streams API의 제약을 우회하는 코드이고, Swift에는 그 제약이
없다. 반대로 **반드시 보존해야 하는 도메인 규칙**도 이 영역에 몰려 있다.

---

## 1. 왜 peek이 필요한가

제약이 사슬처럼 엮여 있다.

```
"같은 turn 안에서 사용자에게 안 보이게 스왑한다"
  -> 스왑 여부가 확정되기 전에는 클라이언트에 한 바이트도 쓸 수 없다
  -> 그런데 429/401은 SSE 스트림의 첫 프레임(event: error)으로도 온다
  -> 그렇다고 응답 전체를 버퍼링하면 긴 답변이 한 번에 쏟아진다
  -> 첫 프레임만 peek해서 판정하고, 통과면 나머지를 프레임 단위로 흘려보낸다
```

마지막 줄이 이 문서 전체의 내용이다.

HTTP `200`으로 시작한 스트림의 첫 프레임이 `event: error`인 경우가 실제로 있다
([02](02-response-classification.md) 2절 참고). status만 보고 통과시키면 이걸 놓친다.

---

## 2. Anthropic이 쓰는 SSE 서브셋

W3C Server-Sent Events 중 실제로 나오는 것만 다룬다.

```
event: <name>\n
data: <payload>\n
data: <payload 이어짐>\n      <- 여러 줄이면 \n으로 join
\n                             <- 빈 줄이 프레임 종단
```

- 종단은 `\n\n` 또는 `\r\n\r\n`
- `:`로 시작하는 줄은 주석(keep-alive) - 무시
- `id:` / `retry:`는 파싱하되 표면화하지 않음
- `event:`가 없으면 이벤트 이름은 빈 문자열

소비자는 둘이다:

| 소비자 | 필요한 것 |
|---|---|
| 분류기 | **첫** 이벤트 (`event: error` 탐지) |
| usage 집계 | **마지막** `message_delta` (토큰 수) |

---

## 3. 프레임 경계 스캐너

**peek은 파싱이 아니다.** 이 단계는 프레임 *경계*만 찾는다. 필드 파싱은 4절의 파서가 한다.

```swift
struct SSEBoundary {
    let index: Int      // 종단이 시작되는 위치
    let length: Int     // 2 (`\n\n`) 또는 4 (`\r\n\r\n`)
}

private let LF: UInt8 = 0x0A
private let CR: UInt8 = 0x0D

/// `\n\n` 또는 `\r\n\r\n`을 바이트 단위로 스캔. 가장 이른 위치의 매치를 반환하며,
/// 같은 인덱스에서 둘 다 시작하면 LF 쪽이 이긴다(정상 CRLF 스트림에서는 발생하지
/// 않지만 tie-break를 결정적으로 두기 위함).
func findSSEBoundary(_ bytes: [UInt8], from: Int) -> SSEBoundary? {
    let n = bytes.count
    guard n >= 2 else { return nil }
    var i = max(0, from)
    while i < n - 1 {
        if bytes[i] == LF, bytes[i + 1] == LF {
            return SSEBoundary(index: i, length: 2)
        }
        if i + 3 < n,
           bytes[i] == CR, bytes[i + 1] == LF,
           bytes[i + 2] == CR, bytes[i + 3] == LF {
            return SSEBoundary(index: i, length: 4)
        }
        i += 1
    }
    return nil
}
```

### 주석 전용 프레임 판정

```swift
/// 종단 빈 줄을 제외한 내용의 모든 비어있지 않은 줄이 `:`로 시작하면 주석 전용.
/// 의도적으로 전체 이벤트 파싱이 아니라 **줄 접두사 검사**만 한다.
func isCommentOnlyFrame(_ content: ArraySlice<UInt8>) -> Bool {
    if content.isEmpty { return true }
    guard let text = String(bytes: content, encoding: .utf8) else { return false }
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
        if line.isEmpty { continue }
        if !line.hasPrefix(":") { return false }
    }
    return true
}
```

선행 `:keepalive\n\n` 프레임은 **건너뛰되 버리지 않는다.** `firstFrameBytes`는 스트림
시작부터 첫 "이벤트를 담은" 프레임 종단까지를 포함하므로, 통과 시 주석까지 원문 그대로
클라이언트에 전달되고 클라이언트의 SSE 파서가 알아서 무시한다.

---

## 4. peek - Swift에서 절반이 사라지는 부분

### Node가 274줄을 쓴 이유

`ReadableStream.getReader()`는 스트림을 **잠근다**. peek을 하고 나면 원본 스트림을
writer에게 넘길 수 없다. 그래서 claulay는:

- 보유한 reader를 감싸는 **새 ReadableStream을 손으로 재조립**하고 (`buildRemainingStream`, ~70줄)
- 경계 이후 이미 읽어둔 tail 바이트를 그 앞에 이어 붙이고
- reader lock 해제를 곳곳에서 방어적으로 처리하고 (`releaseReaderQuietly`)
- `stream.cancel()`이 reader가 잠긴 동안 `TypeError`를 던지므로 **취소 경로를
  `reader.cancel()`로 우회**하며, 그래서 reader 참조를 호출자가 소유해야 한다

**Swift의 `AsyncIterator`는 그냥 들고 있다가 계속 `next()`를 부르면 되는 값이다.**
peek 단계와 릴레이 단계가 같은 iterator를 쓴다. 위 네 항목이 전부 사라진다.

### 구현

```swift
struct PeekResult {
    /// 스트림 시작부터 첫 "이벤트를 담은" 프레임 종단까지 (선행 주석 프레임 포함).
    let firstFrameBytes: [UInt8]
    /// 경계 이후 이미 읽어둔 잔여 바이트. 릴레이 시 이걸 먼저 내보낸 뒤 iterator를 계속 돈다.
    let tail: [UInt8]
    /// 경계를 한 번도 보지 못한 채 업스트림이 닫혔으면 true.
    let closedEmpty: Bool
}

func peekFirstSSEFrame<I: AsyncIteratorProtocol>(
    _ iterator: inout I
) async throws -> PeekResult where I.Element == ByteBuffer {

    var buf: [UInt8] = []
    var frameStart = 0    // 건너뛴 주석 프레임 다음 위치
    var searchFrom = 0    // 증분 스캔 시작점

    while let chunk = try await iterator.next() {
        buf.append(contentsOf: chunk.readableBytesView)

        while true {
            guard let b = findSSEBoundary(buf, from: searchFrom) else {
                // 경계가 청크 사이에 걸칠 수 있으므로 최대 3바이트 되감는다.
                // 가장 긴 종단이 4바이트(`\r\n\r\n`)이므로 3바이트면 충분하다.
                searchFrom = max(searchFrom, max(0, buf.count - 3))
                break
            }
            let endOfFrame = b.index + b.length

            if isCommentOnlyFrame(buf[frameStart..<b.index]) {
                frameStart = endOfFrame
                searchFrom = endOfFrame
                continue
            }

            return PeekResult(
                firstFrameBytes: Array(buf[0..<endOfFrame]),
                tail: Array(buf[endOfFrame...]),
                closedEmpty: false
            )
        }
    }

    // 경계 없이 업스트림 종료
    return PeekResult(firstFrameBytes: buf, tail: [], closedEmpty: true)
}
```

### 크기 상한을 두지 않는다

peek 자체는 10 MiB 첫 프레임도 그대로 반환한다 - 드물지만 적법한 SSE다. 크기 제한은
**호출자의 관심사**이고, 에러 프레임을 버퍼로 내리는 경로(6절)에서만 상한을 건다.

---

## 5. SSE 파서

peek이 찾아준 첫 프레임을 이벤트로 파싱하고, 릴레이 중에는 usage 스니퍼로 동작한다.

```swift
struct SSEEvent: Equatable {
    let event: String   // `event:` 필드. 없으면 빈 문자열
    let data: String    // 여러 `data:` 줄을 \n으로 join
}

struct SSEParser {
    private var lineBuf: [UInt8] = []
    private var currentEvent = ""
    private var currentData: [String] = []
    private var inFrame = false

    /// 청크를 밀어 넣고 완성된 이벤트를 모두 받는다. 부분 줄/부분 프레임은 버퍼링된다.
    mutating func push(_ chunk: [UInt8]) -> [SSEEvent] {
        lineBuf.append(contentsOf: chunk)
        var out: [SSEEvent] = []
        while let nl = lineBuf.firstIndex(of: LF) {
            var lineBytes = Array(lineBuf[..<nl])
            if lineBytes.last == CR { lineBytes.removeLast() }   // CRLF 정규화
            lineBuf.removeFirst(nl + 1)
            if let ev = handleLine(String(decoding: lineBytes, as: UTF8.self)) {
                out.append(ev)
            }
        }
        return out
    }

    /// 종단 빈 줄 없이 업스트림이 깨끗하게 닫혔을 때 남은 이벤트를 흘려보낸다.
    mutating func flush() -> [SSEEvent] {
        var out: [SSEEvent] = []
        if !lineBuf.isEmpty {
            let line = String(decoding: lineBuf, as: UTF8.self)
            lineBuf.removeAll()
            if let ev = handleLine(line) { out.append(ev) }
        }
        if let trailing = emit() { out.append(trailing) }
        return out
    }

    private mutating func handleLine(_ line: String) -> SSEEvent? {
        if line.isEmpty { return emit() }          // 빈 줄 = 프레임 종단
        if line.hasPrefix(":") { return nil }      // 주석

        let colon = line.firstIndex(of: ":")
        let field = colon.map { String(line[..<$0]) } ?? line
        var value = colon.map { String(line[line.index(after: $0)...]) } ?? ""
        if value.hasPrefix(" ") { value.removeFirst() }   // 선행 공백 1개만 제거

        inFrame = true
        switch field {
        case "event": currentEvent = value
        case "data":  currentData.append(value)
        default:      break                        // id / retry / unknown: 수용하되 무시
        }
        return nil
    }

    private mutating func emit() -> SSEEvent? {
        guard inFrame else { return nil }
        let ev = SSEEvent(event: currentEvent, data: currentData.joined(separator: "\n"))
        currentEvent = ""
        currentData.removeAll()
        inFrame = false
        return ev
    }
}
```

### 주의: 바이트 단위로 줄을 자를 것

Node 원본은 청크마다 `chunk.toString('utf8')`로 문자열 변환 후 줄을 자른다. 멀티바이트
UTF-8 시퀀스가 청크 경계에 걸리면 대체 문자가 생긴다.

**Swift에서는 위 코드처럼 `[UInt8]`에 누적하고 `\n`(0x0A)을 바이트로 찾은 뒤 완성된
줄만 디코딩하라.** UTF-8 연속 바이트는 0x80-0xBF, 선두 바이트는 0xC0 이상이라 0x0A가
멀티바이트 시퀀스 안에 나타날 수 없으므로 줄 프레이밍은 안전하고, 줄이 완성된 시점에는
항상 유효한 UTF-8 경계다.

한국어, 이모지가 섞인 응답 델타에서 실제로 차이가 난다.

---

## 6. 통과냐 스왑이냐 - 시도의 두 가지 형태

업스트림 응답은 `content-type`을 보고 한 번만 형태가 결정된다.

```swift
enum UpstreamAttempt {
    /// 응답 전체 바이트를 보유. 풀 소진 시 원문 재생과 분류 양쪽에서 읽는다.
    case buffered(status: Int, headers: HeaderBag, body: [UInt8], isSSE: Bool)

    /// firstFrameBytes로 분류하고, 나머지는 청크 단위로 릴레이한다.
    case streaming(status: Int, headers: HeaderBag, firstFrameBytes: [UInt8], tail: [UInt8])
}
```

union인 이유: 스왑 루프가 **컴파일 타임에** 재생 가능한 버퍼를 쥐고 있는지, 라이브
스트림을 쥐고 있는지 알아야 한다. 하나의 옵셔널 섞인 형태로 만들면 호출 지점마다
`body.count` 검사가 생기고 두 모드 간 조용한 fall-through를 막는 exhaustiveness를 잃는다.

### 첫 프레임이 에러일 때 - 버퍼로 내리기

첫 프레임을 분류한 결과가 스왑 트리거면, **스트리밍을 포기하고 버퍼로 강등**한다.

```swift
// 남은 스트림을 상한까지 드레인해서 buffered로 전환
var body = peek.firstFrameBytes + peek.tail
while body.count <= maxRetryBodyBytes, let chunk = try await iterator.next() {
    body.append(contentsOf: chunk.readableBytesView)
}
let attempt = UpstreamAttempt.buffered(
    status: status, headers: headers, body: body, isSSE: true
)
```

이렇게 하는 이유는 **풀이 소진됐을 때 마지막 실패 응답을 클라이언트에 원문 그대로
재생해야 하기 때문**이다([02](02-response-classification.md) 6절 6단계). 라이브 스트림은
재생할 수 없다.

여기가 크기 상한을 거는 유일한 지점이다.

---

## 7. 릴레이 - backpressure가 공짜가 되는 부분

### Node가 한 일

`res.write()`가 `false`를 반환하면 소켓 버퍼가 찼다는 뜻이다. `'drain'`과 `'close'`에
일회성 리스너를 걸고 경주시킨 뒤, 먼저 발화한 쪽이 promise를 결정한다. 진 쪽이 이미
결정된 promise를 다시 건드리지 않도록 로컬 `settled` 플래그가 필요하고, 안 그러면
`MaxListenersExceededWarning`이 뜬다. `stream-writer.ts`에 이 설명만 40줄이다.

### Swift concurrency가 하는 일

```swift
try await clientChannel.writeAndFlush(chunk).get()
```

**이 `await`가 backpressure 그 자체다.** 이전 쓰기가 완료될 때까지 다음 청크를 당겨오지
않으므로, 느린 클라이언트가 자연스럽게 펌프를 멈춘다. 추가 코드가 없다.

raw NIO 채널 파이프라인으로 간다면 대응물은 `autoRead = false` +
`channelWritabilityChanged`에서 `context.read()`를 부르는 demand-driven 패턴이다.
이것도 프레임워크 레벨이다.

### 전체 릴레이

```swift
func relayStreaming(
    _ attempt: UpstreamAttempt,
    iterator: inout some AsyncIteratorProtocol,
    to client: ClientResponseWriter,
    sniffer: inout SSEParser
) async throws -> ParsedUsage? {

    guard case let .streaming(status, headers, firstFrameBytes, tail) = attempt else {
        preconditionFailure("relayStreaming: buffered attempt은 동기 경로로")
    }
    // [C-56] once-write: 이미 헤더가 나갔거나 소켓이 죽었으면 no-op
    guard !client.headersSent, !client.isActive == false else { return nil }

    do {
        client.writeHead(status: status, headers: headers)     // 정확히 한 번

        try await client.write(firstFrameBytes)
        sniffer.push(firstFrameBytes)

        if !tail.isEmpty {
            try await client.write(tail)
            sniffer.push(tail)
        }

        while let chunk = try await iterator.next() {
            try Task.checkCancellation()
            let bytes = Array(chunk.readableBytesView)

            // [C-63] 두 번째 분류를 하지 않는다. 이 청크가 event: error +
            // rate_limit_error 라 해도 원문 그대로 흘려보내고 클라이언트의 SSE 파서가
            // 표면화하게 둔다. 근거:
            //   - once-write 불변식이 두 번째 writer를 금지한다. 바이트가 소켓을
            //     건넌 뒤에는 계정을 바꿀 수 없다.
            //   - 첫 프레임 에러는 6절의 버퍼 강등이 이미 처리했다. 스트림 중간
            //     에러는 same-turn 스왑을 하기엔 너무 늦었다.
            try await client.write(bytes)
            sniffer.push(bytes)
        }

        client.end()
        return sniffer.finishUsage()

    } catch {
        // 두 원인이 여기로 수렴한다:
        //  (a) 클라이언트 소켓이 중간에 끊김 - 정리할 것이 없음
        //  (b) 업스트림이 중간에 실패 (소켓 리셋, 타임아웃) - 클라이언트 소켓은
        //      아직 살아있고 헤더+부분 프레임이 이미 건너갔으므로 once-write가
        //      에러 body 작성을 금지한다
        try? await client.abort()   // 주의: end()가 아니다 - 아래 참고
        return nil                  // 호출자는 usage 기록을 건너뛴다
    }
}
```

### 주의: 중간 실패 시 `end()`가 아니라 강제 종료

업스트림이 스트림 중간에 죽었을 때 깨끗하게 `end()`를 부르면 **chunked 종단자가
전송되어 잘린 스트림이 완결된 것처럼 보인다.** Claude Code에서 "Response stalled
mid-stream"으로 나타나던 증상이 이것이다 - 클라이언트가 죽은 업스트림과 느린
업스트림을 구분할 수 없다.

소켓을 끊어야 클라이언트가 즉시 연결 오류를 관측하고 재시도할 수 있다.

**Swift/NIO 대응:** `HTTPServerResponsePart.end(nil)`을 **보내지 말고** 채널을 직접
`close(mode: .all)` 한다. `.end` 파트를 보내면 종단 청크가 나간다.

### 취소

Node는 `res.once('close', onClose)` -> `onClose`가 `reader.cancel()`을 멱등하게 호출 ->
대기 중인 read가 `done:true`로 풀리며 루프 탈출, 게다가 read 사이에 취소가 발생하는
경우를 위한 `isCanceled()` 폴링까지 필요하다.

Swift는 구조적 동시성이다. 클라이언트 연결이 끊기면 릴레이 Task를 취소하고,
`try await iterator.next()`가 `CancellationError`를 던지며, `defer`가 업스트림 요청을
정리한다. `Task.isCancelled` / `Task.checkCancellation()`이 `isCanceled()`를 대체한다.

취소 시 사용자에게 이미 청구된 토큰이 더 늘지 않도록 **업스트림 소켓까지 즉시 abort가
전파되어야 한다**는 계약은 그대로 유지된다.

---

## 8. 보존해야 하는 불변식

프레임워크가 바뀌어도 이건 도메인 규칙이다.

| 불변식 | 내용 | 어기면 |
|---|---|---|
| **once-write** | 응답 하나당 `writeHead` 정확히 1회. 이후 write 0회 이상, `end` 최대 1회 | 이중 응답, 프로토콜 깨짐 |
| **no second classify** | 첫 프레임 이후 도착한 바이트는 절대 재분류하지 않음 | 바이트가 나간 뒤 스왑 시도 -> once-write 위반 |
| **버퍼 강등** | 첫 프레임이 에러면 나머지를 상한까지 드레인해 buffered로 전환 | 풀 소진 시 원문 재생 불가 |
| **강제 종료** | 중간 실패 시 chunked 종단자를 보내지 않고 소켓을 끊음 | 클라이언트가 조용히 멈춤 |
| **선행 주석 보존** | 건너뛴 `:keepalive` 프레임도 `firstFrameBytes`에 포함해 원문 전달 | 클라이언트 파서 상태 불일치 |
| **취소 전파** | 클라이언트 중단 시 업스트림까지 즉시 abort | 토큰 추가 소모 |

---

## 9. Node 대비 사라지는 것 / 남는 것

| claulay | LOC | Swift |
|---|---|---|
| `buildRemainingStream` (reader 재조립) | ~70 | **없음** - 같은 iterator 계속 사용 |
| `releaseReaderQuietly` / lock 관리 | ~30 | **없음** |
| `writeWithBackpressure` (drain/close 경주 + `settled`) | ~50 | **없음** - `await`가 backpressure |
| `onClose` 멱등 처리 + `isCanceled()` 폴링 | ~40 | **없음** - `Task.checkCancellation()` |
| 경계 스캐너 + 주석 건너뛰기 | ~60 | **그대로 필요** |
| SSE 필드 파서 | ~100 | **그대로 필요** (+ 바이트 단위 줄 자르기로 개선) |
| 버퍼 강등 / once-write / no-second-classify | ~80 | **그대로 필요** |

대략 **~190줄이 사라지고 ~240줄이 남는다.** 사라지는 쪽은 전부 프레임워크 우회 코드고,
남는 쪽은 전부 도메인 규칙이다.

---

## 10. 테스트 케이스

### `peekFirstSSEFrame` (`stream-peek.test.ts`)

| # | 케이스 | 기대 |
|---|---|---|
| 1 | 단일 청크에 완전한 프레임 | 첫 프레임 바이트 반환 + 나머지 릴레이 |
| 2 | **분할 패킷 경계** | TCP 청크를 가로질러 누적하고 경계를 찾는다 |
| 3 | **CRLF 정규화** | `\r\n\r\n`을 `\n\n`과 동등한 경계로 처리 |
| 4 | **선행 주석 프레임** | `:keepalive\n\n`을 누적하고 첫 실제 이벤트 프레임까지의 바이트를 반환 |
| 5 | 경계 전에 업스트림 종료 | `closedEmpty: true` + 도착한 바이트 + 이미 닫힌 잔여 |
| 6 | **8 KiB 초과 첫 프레임** | 잘림 없이 peek |
| 7 | 첫 프레임 직후 스트림 종료 | 경계를 봤으므로 `closedEmpty: false`, tail은 빈 배열 |

2, 3, 6번이 특히 중요하다. 순진한 구현이 전부 여기서 깨진다.

### `SSEParser` (`sse-parser.test.ts`)
- 여러 `data:` 줄을 `\n`으로 join한다
- `:` 주석 줄을 무시한다
- 값의 선행 공백을 **1개만** 제거한다
- `event:`가 없으면 이벤트 이름이 빈 문자열이다
- `id:` / `retry:`를 수용하되 표면화하지 않는다
- 종단 빈 줄 없이 닫히면 `flush()`가 마지막 이벤트를 낸다
- **(추가)** 멀티바이트 UTF-8이 청크 경계에 걸려도 손상되지 않는다 <- Swift 전용

### 릴레이 (`stream-writer.test.ts`)
- `headersSent`가 이미 true면 no-op이다 (once-write)
- 소켓이 죽었으면 `writeHead` 전에 단락한다
- 중간 청크가 `event: error`여도 **재분류하지 않고** 원문 전달한다
- 업스트림 중간 실패 시 `end()`가 아니라 **소켓을 끊는다**
- 클라이언트 중단 시 업스트림 취소가 전파된다
- 취소된 경우 usage를 기록하지 않는다

---

## 11. 다음

- `state/selector.ts` - 우선순위 선택과 `(account, model)` 쿨다운 맵
- `telemetry/ratelimit-tracker.ts` - `anthropic-ratelimit-unified-*` 파싱, 선제 전환 데이터
- `audit/usage-log.ts` - usage.jsonl 스키마 (캐시 토큰 필드 포함)
