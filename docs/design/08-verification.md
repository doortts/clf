# 08. 단계별 실행과 외부 검증

앱을 다 만든 뒤에 처음 돌려보면 어디가 틀렸는지 알 수 없다. 이 문서는 두 가지를
정한다. 각 단계를 **완성 전에 손으로 실행하는 방법**과, 프록시가 도는 동안
**내부 상태를 밖에서 읽는 방법**이다.

---

## 1. 왜 따로 만드는가

메뉴바 앱은 관찰하기 나쁜 실행 환경이다.

- 화면이 좁다. 조직 다섯 개의 세 창을 동시에 보여줄 자리가 없다
- 상태가 순간적이다. 스왑은 200ms 안에 끝나고 UI 는 결과만 보여준다
- 재현이 어렵다. 한도에 실제로 걸릴 때까지 기다릴 수 없다
- 앱 번들이 필요하다. 서명, Info.plist, Xcode 프로젝트를 거쳐야 한 줄을 확인한다

그래서 관찰과 조작을 앱 밖으로 뺀다. 앱은 사용자가 쓰는 표면이고, 검증은
별도 표면이다.

---

## 2. 세 층

```
clflctl              터미널에서 단계를 실행한다. 앱 없이 돈다
  |
  +-- 컨트롤 플레인   프록시가 도는 동안 내부 상태를 읽는다. 읽기 전용 HTTP
  |
  `-- jsonl 로그      끝난 뒤 조인해서 본다. usage.jsonl, audit.jsonl
```

셋이 겹치는 부분이 있는데 의도한 것이다. 같은 사실을 서로 다른 시간대에 본다.
`clflctl` 은 요청 **전**, 컨트롤 플레인은 요청 **중**, jsonl 은 요청 **후**다.

---

## 3. 같은 레코드 원칙

관찰용 코드가 실제 판정과 다른 답을 내면 없느니만 못하다. 그래서 판정 함수가
**이유를 값으로 낸다.**

```swift
public func select(_ input: SelectionInput) -> SelectionResult {
    explain(input).result          // select 는 explain 의 얇은 껍질이다
}

public func explain(_ input: SelectionInput) -> SelectionExplanation
```

`SelectionExplanation` 은 결과와 후보별 `CandidateVerdict` 를 함께 담는다.
`clflctl select` 가 그리는 표, 컨트롤 플레인의 `GET /select`, 요청 트레일의
`candidates` 필드가 전부 이 하나의 레코드다.

두 경로로 갈라 두면 설명이 언제든 거짓말을 시작한다. 테스트가 그것을 잠근다
(`test_explainAgreesWithSelect`).

여유 값도 같은 규칙을 따른다. 표에 찍히는 `여유` 는 표시용으로 다시 계산한
값이 아니라 강등 판정이 실제로 쓴 `bindingHeadroom` 그 값이다.

---

## 4. 검증 사다리

[04 구현 설계](04-implementation.md) 9절의 단계마다 실행 명령과 통과 기준을 붙인다.
윗 단계가 통과해야 아랫 단계로 간다.

| 단계 | 무엇 | 실행 | 통과 기준 | 상태 |
|---|---|---|---|---|
| 1-5 | ClflCore | `swift test --filter ClflCoreTests` | 전부 통과 | 됨 |
| 6 | ClflStore | `swift test --filter ClflStoreTests` | 전부 통과 | 됨 |
| 6a | 환경 점검 | `clflctl doctor` | 실패 항목 0 | 됨 |
| 6b | 조직 등록 | `clflctl accounts add` | `list` 에 뜨고 Keychain 있음 | 됨 |
| 6c | 설정 주입 | `clflctl settings install` | `show` 가 주입됨을 말한다 | 됨 |
| 6d | 선택 판정 | `clflctl runtime simulate` + `select` | 표가 예상과 같다 | 됨 |
| 6e | 응답 분류 | `clflctl classify` | 네 경로가 갈린다 | 됨 |
| 6f | SSE 경계 | `clflctl sse-peek` | 주석 프레임을 건너뛴다 | 됨 |
| 7 | 업스트림 | `clflctl upstream probe <id>` | 실제 200 과 사용량 헤더 | 도구는 됨 |
| 8 | 프록시 단일 조직 | `clflctl serve --single <id>` | **Claude Code 데스크톱 앱으로 대화 성공** | 도구는 됨 |
| 9 | 스왑 | `clflctl serve` + `runtime simulate` | 스왑 발생, 트레일에 기록 | 아직 |
| 10 | 컨트롤 플레인 | `clflctl watch` | 스왑이 실시간으로 흐른다 | 아직 |
| 11 | 앱 | Xcode | 메뉴바에 같은 값이 뜬다 | 아직 |

8번이 첫 관문이라는 판단은 그대로다. 다만 이제 그 앞에 손으로 밟을 수 있는
디딤돌이 여섯 개 있다.

### 격리

실험이 실제 설정을 건드리면 안 된다. 세 가지를 전부 밖에서 갈아끼운다.

```bash
clflctl select \
  --data-dir /tmp/clfl-demo/data \
  --claude-dir /tmp/clfl-demo/claude \
  --keychain-service me.clfl.demo
```

디렉토리만 바꾸면 격리가 반쪽이다. 자격증명은 여전히 진짜 Keychain 으로 간다.
그래서 서비스 이름도 연다.

### 상태를 손으로 만든다

한도에 실제로 걸릴 때까지 기다릴 수 없으므로 런타임 상태를 심는다.

```bash
clflctl runtime simulate team1 --rate-limit 600      # 이 모델만 10분 막는다
clflctl runtime simulate team1 --session-limit 1800  # 계정 전체를 30분 막는다
clflctl runtime simulate team1 --invalid             # 자격증명 무효로 표시
clflctl runtime simulate team1 --headroom 0.03       # 5시간 창 잔여를 3% 로
clflctl runtime clear                                # 되돌린다
```

`select` 가 그 상태로 판정을 다시 돌린다.

```
  순위  id             판정  여유  이유
  ----  -------------  ----  ----  ------------------------------------
  1     naver_team_40  제외  -     claude-opus-4-5 쿨다운 19:40:08 까지
  2     naver_team_52  선택  3%    선택
  3     ent1           후보  -     대기 (tier 1)
```

---

## 5. 컨트롤 플레인

프록시가 도는 동안 내부 상태를 읽는 읽기 전용 HTTP 표면이다.

### 별도 포트를 쓴다

프록시 포트에 `/_clfl/...` 같은 경로를 얹지 않는다. 이유가 셋이다.

- **표면이 겹친다.** Anthropic API 밖의 경로를 우리가 가로채기 시작하면
  클라이언트가 새 엔드포인트를 쓸 때 조용히 충돌한다. 요청마다 우리 경로인지
  검사하는 분기도 생긴다
- **수명이 다르다.** 프록시가 포트 바인딩에 실패했을 때가 바로 상태를 봐야 할
  때다. 컨트롤 플레인이 프록시에 매달려 있으면 그 순간 아무것도 못 본다
- **노출 표면을 묶지 않는다.** 하나가 새면 둘 다 샌다

### 엔드포인트

전부 `GET` 이고 전부 JSON 이다. 상태를 바꾸는 엔드포인트는 두지 않는다.

| 경로 | 내용 |
|---|---|
| `/health` | 떠 있는지, 프록시가 어느 포트에 붙었는지, 얼마나 됐는지 |
| `/state` | `RouterSnapshot`. 조직, 우선순위, 런타임, 활성, 지속 조건 |
| `/select?model=&start=` | 지금 요청이 오면 어디로 가는지. 4절의 표와 같은 레코드 |
| `/requests?limit=50` | 최근 요청의 결정 트레일. 메모리 링 버퍼 |
| `/events` | SSE. 스냅샷 변화와 `RoutingEvent` 를 실시간으로 |

### 요청 트레일

`audit.jsonl` 은 **사건**을 남긴다. 트레일은 **판단 과정**을 남긴다. 둘은 다르다.
스왑이 일어난 것은 audit 에 있지만, 왜 team2 를 건너뛰고 ent1 로 갔는지는 없다.

```json
{"at":"...","sessionId":"...","model":"claude-opus-4-5",
 "candidates":[{"id":"team1","disposition":"cooling","headroom":null},
               {"id":"team2","disposition":"chosen","headroom":0.41}],
 "attempts":[{"account":"team1","status":429,"errorType":"rate_limit_error",
              "trigger":"rate_limit","resetAt":"..."},
             {"account":"team2","status":200,"ttfbMillis":840}],
 "outcome":"swapped"}
```

메모리 링 버퍼 200개. 디스크에 쓰지 않는다. 진단용이라 재시작을 넘길 이유가 없고,
남기기 시작하면 무엇을 지워야 하는지를 다시 정해야 한다.

### 보안

- **loopback 전용.** `127.0.0.1` 에만 바인딩한다
- **읽기 전용.** 상태를 바꾸는 경로가 없으므로 CSRF 를 생각할 일이 없다
- **자격증명을 싣지 않는다.** `RouterSnapshot` 타입 자체가 토큰을 갖지 않는다.
  규율이 아니라 타입으로 막는다
- **기본 꺼짐.** `--control-port` 를 주거나 설정에서 켜야 뜬다

같은 사용자의 다른 프로세스는 읽을 수 있다. 조직 이름과 사용량이 노출되고
자격증명은 아니다. 기본을 꺼둠으로써 켠 사람만 그 대가를 진다.

---

## 6. clflctl 명령 요약

### 설치

`.build/debug/clflctl` 은 상대 경로라 저장소 밖에서 부를 수 없고, 빌드를 다시
돌리면 자리가 바뀔 수 있다. 릴리스로 빌드해 PATH 에 링크한다.

```bash
./scripts/install-clflctl.sh
```

기본 대상은 `~/.local/bin` 이고 `CLFL_BIN_DIR` 로 바꾼다. 심볼릭 링크라
다시 빌드하면 링크가 새 바이너리를 가리킨다.

```
clflctl doctor                          환경 점검. 실패마다 고치는 법을 함께 말한다

clflctl settings show                   ~/.claude/settings.json 의 env 블록
clflctl settings install --port 51710
clflctl settings uninstall

clflctl accounts list                   우선순위 순으로
clflctl accounts add <id> --plan team   토큰은 stdin 으로만 받는다
clflctl accounts remove <id>
clflctl accounts enable|disable <id>
clflctl accounts priority <id>...

clflctl runtime show                    조직별 세 창과 구속 여유
clflctl runtime simulate <id> ...       상태를 손으로 심는다
clflctl runtime clear [<id>]

clflctl select [--model] [--start]      선택 판정과 후보별 이유
clflctl classify --status 429 ...       응답 하나를 분류기에 먹인다
clflctl sse-peek <file>                 첫 이벤트 프레임 경계

clflctl upstream probe <id> [--stream]  실제 왕복 한 번
clflctl serve --single <id> [--install] 프록시를 띄운다
```

토큰을 인자로 받지 않는다. argv 는 셸 히스토리에 남는다.

```bash
pbpaste | clflctl accounts add team1 --plan team
```

---

## 7. 도구가 이미 잡아낸 것

만들자마자 세 가지가 드러났다. 이것이 이 계층을 먼저 만드는 이유다.

**상태 코드만으로는 스왑하지 않는다.** 본문 없이 `--status 429` 만 주면 통과
판정이 나온다. 분류기가 옳다. `error.type` 을 못 읽으면 통과가 계약이다. 다만
도구가 그 이유를 말하지 않으면 사람이 분류기를 의심한다. 그래서 `classify` 가
추출한 `error.type` 을 항상 함께 찍는다.

**중복 토큰 등록이 막힌다.** 같은 토큰을 다른 id 로 넣으면 지문이 걸린다.
조직 셋이 같은 이메일을 쓰는 환경에서 이것이 유일한 중복 방지선이다.

**tier 1 안의 순서가 미정이다.** 아래로 옮긴다.

---

## 7-1. 7단계에서 실제로 나온 것

TDD 로 진행했다. 테스트를 먼저 쓰고 빨간 것을 확인한 뒤 구현했다. 그 순서가
아니었으면 놓쳤을 것 넷이 나왔다.

**스캐폴딩 enum 이 릴레이를 불가능하게 만들고 있었다.** `UpstreamAttempt.streaming`
이 첫 프레임과 잔여 바이트만 들고 남은 스트림을 들지 않았다. peek 이 끝난 뒤
이어서 읽을 방법이 타입에 없었다는 뜻이다. `rest: UpstreamByteStream` 을 케이스
안에 넣었다. 밖에 두면 스트림 없이 릴레이를 부르는 조합이 타입상 가능해지고,
그 경우 클라이언트는 첫 프레임만 받고 대화가 멈춘 것처럼 본다.

**연결 타임아웃 기본값이 10초였다.** 닿지 않는 조직 하나가 요청을 10초씩 붙잡는다.
조직 셋이면 30초라 풀 grace 예산 15초를 훌쩍 넘겨 스왑이 의미를 잃는다. 5초로
내렸다. 테스트가 10초 걸리는 것을 보고 알았다.

**peek 은 필요한 만큼만 읽는다.** 1바이트씩 들어오는 스트림에서 경계를 완성한
청크가 마지막으로 읽은 것이므로 tail 이 비고 나머지는 iterator 에 남는다.
미리 읽어두면 그만큼 첫 바이트가 늦는다. 처음에는 이걸 버그로 착각하고 테스트를
잘못 썼다.

**가짜 업스트림이 헤더 경계를 문자 수로 세고 있었다.** 본문이 별도 세그먼트로
오면 부분 디코딩이 대체 문자를 만들어 경계가 어긋나고, 본문이 도착하기 전에
응답해버린다. 드물게 실패하는 테스트로 나타났다. 바이트로 세도록 고쳤다.
이 fixture 는 8, 9단계에서도 쓰므로 여기서 잡는 편이 싸다.

### 압축 자동 해제를 어떻게 잠갔나

문서가 경고만 하고 있으면 언젠가 누가 끈다. mtime 을 0 으로 고정한 gzip 바이트를
fixture 에 박아두고, 가짜 업스트림이 그것을 `content-encoding: gzip` 으로 보낸다.
해제가 꺼지면 peek 이 gzip 바이트를 읽어 `parseFirstSSEEvent` 가 nil 을 내므로
테스트가 즉시 빨개진다.

---

## 7-2. 8단계에서 나온 것

같은 방식으로 진행했다. 릴레이 15개, 서버 11개, 단일 조직 핸들러 16개를 먼저 쓰고
빨간 것을 확인한 뒤 구현했다.

**릴레이의 불변식을 호출 기록으로 표현했다.** 가짜 클라이언트가 writeHead, write,
end, abort 를 순서대로 적기만 하면 불변식 검증이 끝난다. 무엇을 언제 몇 번 불렀나가
곧 계약이기 때문이다. `end` 와 `abort` 를 가르는 테스트가 특히 그렇다. 중간에 끊긴
스트림에 `end()` 를 부르면 chunked 종단자가 나가 잘린 응답이 완결된 것처럼 보이고,
Claude Code 에서는 "Response stalled mid-stream" 으로 나타난다.

**프레이밍을 서버가 정해야 했다.** 릴레이가 `content-length` 를 떼므로 응답에
길이 정보가 없다. 그대로 두면 NIO 가 연결 종료로 본문 끝을 표시하는데 그러면
keep-alive 가 깨진다. 길이가 없을 때 `transfer-encoding: chunked` 를 붙인다.

**settings.json 에 URL 이 `http:\/\/...` 로 적히고 있었다.** 유효한 JSON 이고
Claude Code 도 잘 읽지만 사용자가 열어보고 손으로 고치는 파일이다.
`JSONSerialization` 의 `withoutEscapingSlashes` 를 켰다. 실제로 띄워 보고 파일을
열어보지 않았으면 못 봤을 것이다.

**니글 알고리즘을 꺼야 했다.** `tcp_nodelay` 없이는 작은 SSE 프레임이 커널에서
뭉쳐 나간다. 프레임이 하나씩 도착하는지 세는 테스트가 그것을 잡는다.

### 8단계에서 확인한 것

가짜 업스트림(gzip SSE)에 붙여 전 경로를 태웠다.

- 업스트림의 gzip 이 클라이언트에 평문으로 도착한다
- `anthropic-beta` 가 병합된다. 클라이언트가 보낸 `claude-code-20250219` 를
  덮지 않고 `claude-code-20250219, oauth-2025-04-20` 이 된다
- 클라이언트의 `authorization` 과 `host` 가 우리 것으로 바뀐다
- `x-claude-session-id` 가 그대로 넘어가고 usage.jsonl 에 실린다
- 캐시 두 필드가 기록된다
- Ctrl-C 가 settings.json 을 원래대로 되돌린다. 남의 키는 그대로다

**아직 통과가 아니다.** 사다리 8칸의 기준은 도구가 도는 것이 아니라 Claude Code
데스크톱 앱으로 대화가 성립하는 것이다. 실제 조직 등록이 필요하므로 사용자가
직접 밟아야 한다.

```
clflctl accounts add <id> --plan team    # 토큰은 stdin
clflctl serve --single <id> --install
```

---

## 7-3. 8단계 실기기 확인 절차

도구가 도는 것과 Claude Code 데스크톱 앱으로 대화가 성립하는 것은 다르다.
이 절이 그 사이를 잇는다.

### 준비

```bash
./scripts/install-clflctl.sh      # 릴리스로 빌드해 ~/.local/bin 에 링크
clflctl doctor                    # 무엇이 빠졌는지
```

`doctor` 가 조직 없음이라고 하면 등록한다. 토큰은 stdin 으로만 받는다.
ANSI 제어 문자와 프롬프트 장식은 도구가 걷어낸다.

```bash
claude setup-token | clflctl accounts add naver_team_40 --plan team
```

### 7칸 먼저

프록시를 띄우기 전에 왕복 한 번으로 자격증명과 헤더를 확인한다. 여기서
막히면 프록시 문제가 아니다.

```bash
clflctl upstream probe naver_team_40 --stream --save
```

- `평문 예` 라야 압축 자동 해제가 살아 있는 것이다
- 사용량 표가 나오면 헤더 편승 관측이 되는 것이다
- 401 이면 자격증명 문제다. 프록시로 넘어가지 않는다

### 8칸

```bash
clflctl serve --single naver_team_40 --install
```

`--install` 은 **바인딩에 성공한 뒤에** `settings.json` 을 고친다. 순서를
뒤집으면 앱 없이 설정만 남아 Claude Code 가 통째로 고장 난 것처럼 보인다.
Ctrl-C 가 되돌린다.

그 다음 **Claude Code 데스크톱 앱을 완전히 종료하고 다시 연다.** `env` 는
프로세스가 뜰 때 읽히므로 켜둔 채로는 새 설정을 보지 못한다.

### 무엇을 보는가

요청마다 한 줄이 나온다.

```
  21:41:28  POST  /v1/messages  team1  opus-4-5  SSE  s:sess-abc  200  278B  첫바이트 25ms  총 26ms
```

이 한 줄이 8단계 관측의 전부다. 확인할 것은 넷이다.

| 보는 것 | 통과 | 아니면 |
|---|---|---|
| 대화가 되는가 | 응답이 흐른다 | 줄의 `실패:` 뒤에 이유가 있다 |
| 세션 id 가 오는가 | `s:` 로 시작하는 값 | `세션없음`. 대화 시작 판정이 불가능해진다 |
| 스트리밍인가 | `SSE` 표시 | 없으면 버퍼 응답이다 |
| 체감이 느린가 | 첫바이트 수백 ms | 초 단위면 어딘가 막힌다 |

MCP 도구 검색은 로그가 아니라 앱에서 본다. 도구 목록이 평소대로 뜨는지,
`ENABLE_TOOL_SEARCH` 복구가 실제로 먹히는지 확인한다.

원격 제어는 되살릴 방법이 없다. `api.anthropic.com` 이 아니면 동작하지 않는
것이 클라이언트 정책이다.

### 되돌리기

Ctrl-C 가 정상 경로다. 강제 종료로 죽였거나 설정이 남았으면 직접 되돌린다.

```bash
clflctl settings uninstall
```

`settings.json` 을 열어 `env` 에 `ANTHROPIC_BASE_URL` 이 없으면 복구된 것이다.
설치 전 원본은 `settings.json.clfl.bak` 에도 있다.

---

## 8. 열린 질문

### tier 1 안에서 무엇을 먼저 쓸 것인가

현재는 우선순위 순서다. 그래서 4절 예시에서 잔여 3% 인 `naver_team_52` 가
읽기가 없는 `ent1` 보다 앞선다. 둘 다 tier 1 이고 priority 가 앞서기 때문이다.

3% 인 조직은 거의 확실히 429 를 맞는다. 읽기가 없는 조직은 알 수 없다.
아는 실패와 모르는 상태를 같은 칸에 두고 우선순위로 자르면, 곧 실패할 것을
알면서 그쪽으로 보낸다. 반응형 경로가 그것을 받아내지만 캐시는 이미 잃는다.

두 갈래가 있다.

- **지금 그대로.** priority 는 사용자 의사다. 읽기가 없다는 것은 안 써봤다는
  뜻일 수 있고, 검증되지 않은 조직으로 대화를 시작하는 것도 대가가 있다
- **tier 1 을 둘로 쪼갠다.** 읽기 없음을 잔여 낮음보다 앞에 둔다. 선제 강등이
  대화 시작에만 걸리므로 영향 범위가 좁다

측정 없이 정하지 않는다. `usage.jsonl` 과 `audit.jsonl` 을 조인하면 스왑이
유발한 캐시 재생성 비용이 나온다. 8번 단계 이후에 실측으로 정한다.

### 아직 없는 것

| 항목 | 언제 |
|---|---|
| `clflctl watch` | 10단계. 컨트롤 플레인 구독 |
| 컨트롤 플레인 본체 | 프록시가 생긴 뒤. 붙일 상태가 있어야 한다 |
| 시나리오 재생 | 가짜 업스트림으로 스왑 루프 전체를 오프라인 재생 |
