# 19. Antigravity 계정 사용량

Claude 와 Codex 카드 옆에 Google Antigravity 카드를 둔다. 5시간 창과 주간 창,
리셋까지 남은 시간, 플랜 배지, 메뉴바 막대까지 같은 자리에 같은 규칙으로 그린다.

**할 수 있다. 다만 Antigravity 앱이 떠 있는 동안만이다.** 2026-09-16 에 이
기계에서 확인했다. 앱 버전 2.12.2, 번들 `com.google.antigravity`. 근거는 1절.
같은 날 구현했다. `AntigravityUsage.swift`, `AntigravityReader.swift` 와
`AntigravityUsageTests`.

앞의 둘과 갈리는 대목이 이것 하나다. Claude 와 Codex 는 디스크의 토큰으로
서버에 직접 물어서 앱이 꺼져 있어도 읽힌다. Antigravity 는 토큰이 디스크에
없고, 읽을 창구가 앱이 띄우는 로컬 서버뿐이다.

**카드는 두 줄이다.** 서버는 네 칸을 주지만 둘만 쓴다. 왜 그런지는 3-2절.

---

## 1. 가능 여부: 확인한 것과 못 한 것

### 1-1. 토큰이 디스크에 없다

먼저 앞의 둘과 같은 길을 찾아봤고 없었다.

| 찾은 곳 | 결과 |
|---|---|
| `~/.gemini/antigravity/`, `~/.gemini/antigravity-cli/` | 상태와 대화 기록뿐. 토큰 없음 |
| `~/.gemini/config/config.json`, `~/.gemini/settings.json` | 설정과 플러그인 목록뿐 |
| Keychain (`Antigravity`, `Antigravity Safe Storage`) | 항목 자체가 없다 |
| `~/Library/Application Support/Antigravity/` | Chromium 프로필. 쿠키와 Local Storage 에 사용량 흔적 없음 |

디스크 어디에도 `remainingFraction` 이나 버킷 이름(`gemini-5h`, `3p-weekly`)이
없다. **사용량을 파일에서 읽어내는 길은 없다.**

### 1-2. 앱이 로컬 RPC 서버를 띄운다

앱은 자식 프로세스로 `language_server` 를 띄운다. Codeium 계열 구조 그대로다.

```
/Applications/Antigravity.app/Contents/Resources/bin/language_server
  --standalone
  --override_ide_name antigravity
  --csrf_token <매번 새로 만드는 UUID>
  --api_server_url https://generativelanguage.googleapis.com
  --cloud_code_endpoint https://daily-cloudcode-pa.googleapis.com
```

이 프로세스가 루프백에 포트 둘을 연다. 실측으로 낮은 쪽이 HTTPS, 높은 쪽이
평문 HTTP 다. **포트 번호도 CSRF 토큰도 앱을 띄울 때마다 바뀐다.** 둘 다
`ps` 의 명령줄에 있으므로 거기서 읽는다.

```
POST http://127.0.0.1:<포트>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary
x-codeium-csrf-token: <위에서 읽은 값>
content-type: application/json

{}
```

헤더 이름이 `x-codeium-csrf-token` 이다. 앱 이름이 Antigravity 로 바뀌었어도
프로토콜 쪽 이름은 Codeium 시절 그대로다. `x-csrf-token` 을 비롯한 다른
후보는 전부 `401 {"code":"unauthenticated","message":"missing CSRF token"}` 을
낸다.

**추론 요청이 아니다.** 사용량을 소모하지 않는다. 게다가 서버가 값을 들고
있어서 첫 호출이 17밀리초, 그다음은 1밀리초 아래다.

플랜은 다른 RPC 에 있다. `GetUserStatus` 가 `planName: "Pro"` 와
`teamsTier: "TEAMS_TIER_PRO"` 를 준다.

### 1-3. 응답은 두 묶음에 네 칸이다

```json
{"response": {
  "groups": [
    {"displayName": "Gemini Models",
     "description": "Models within this group: Gemini Flash, Gemini Pro",
     "buckets": [
       {"bucketId": "gemini-weekly", "window": "weekly",
        "remainingFraction": 1, "resetTime": "2026-09-23T08:01:03Z"},
       {"bucketId": "gemini-5h", "window": "5h",
        "remainingFraction": 1, "resetTime": "2026-09-16T13:01:03Z"}]},
    {"displayName": "Claude and GPT models",
     "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
     "buckets": [
       {"bucketId": "3p-weekly", "window": "weekly", ...},
       {"bucketId": "3p-5h", "window": "5h", ...}]}
  ]
}}
```

**모델 묶음이 둘이고 묶음마다 창이 둘이라 칸이 넷이다.** 둘째 묶음은
Antigravity 안에서 Claude 나 GPT 모델을 골라 쓸 때만 닳는 별도 주머니다.
사용자의 Claude 구독과도, Codex 구독과도 무관하다. 우리는 첫째 묶음만
그린다 (3-2절).

**서버가 주는 값이 잔여다.** `remainingFraction` 은 0 에서 1 사이 소수이고
1 이 가득 남은 것이다. Claude 와 Codex 는 사용률을 주고 우리가 잔여를
파생시켰는데 여기는 방향이 반대다. `percentUsed` 를 우리가 파생시킨다.

### 1-4. 안 쓴 창은 리셋 시각이 흐른다

같은 창을 5분 30초 간격으로 두 번 읽었다.

```
1회  gemini-5h  remaining 1  reset 2026-09-16T12:55:33Z
2회  gemini-5h  remaining 1  reset 2026-09-16T13:01:03Z
```

리셋 시각이 딱 그만큼 밀렸다. **지금 시각에 창 길이를 더한 값**이라는 뜻이고,
타이머가 안 걸린 창이다. Codex 에서 겪은 것과 같은 함정이라
([18 문서](18-codex-usage.md) 1-2절) 대처도 같다. `remainingFraction` 이 1 이면
리셋 시각을 버리고 `창 안 열림` 으로 둔다.

### 1-5. 확인하지 못한 것

| 무엇 | 지금 아는 것 | 대처 |
|---|---|---|
| `language_server` 가 클라우드에서 언제 다시 받나 | 응답이 1밀리초에 오는 것으로 보아 들고 있는 값이다. 갱신 시점은 모른다 | 우리 갱신 주기(5분)로 계속 묻는다. 로컬이라 공짜다. 값이 늦으면 그건 앱이 늦은 것이고 앱 화면도 같이 늦다 |
| 429 나 과호출 정책 | 로컬 서버라 해당 없어 보인다. 클라우드로 새어 나가는지는 모른다 | Claude, Codex 와 같은 `ReadGate` 뒤에 둔다. 갈래가 같아야 한 자리에서 다룬다 |
| 잔여가 실제로 줄어드는 모습 | 관측 못 했다. 읽는 동안 네 칸이 전부 1 이었다 | 값의 뜻은 필드 이름과 방향이 분명하다. 다만 **다 쓴 창은 `remainingFraction` 이 아예 안 온다고 보고 0 으로 읽는다.** 이 응답은 protobuf JSON 이라 기본값 필드를 안 싣는다. 그 전제가 틀리면 소진된 창이 통째로 사라지고 알림도 안 나가므로, 안 싣는 쪽에 걸었다 |
| 플랜마다 묶음 구성이 같은가 | `Pro` 하나만 봤다 | 버킷 이름으로 고르고, 못 찾으면 첫째 묶음으로 떨어진다 (3-2절) |
| Enterprise 나 무료 플랜 | 관측 없음 | 위와 같다. `groups` 가 비면 보여줄 것이 없는 계정이다 |

---

## 2. 앞의 둘과 무엇이 다른가

| | Claude | Codex | Antigravity |
|---|---|---|---|
| 읽는 곳 | 원격 API | 원격 API | **로컬 RPC** |
| 앱이 꺼져 있으면 | 읽힌다 | 읽힌다 | **못 읽는다** |
| 토큰 | `config.json` 암호문 | `auth.json` 평문 | 디스크에 없다 |
| 접속 정보 | 고정 주소 | 고정 주소 | **앱을 띄울 때마다 바뀌는 포트와 토큰** |
| 서버가 주는 값 | 사용률 | 사용률 | **잔여** |
| 응답의 칸 | 셋 | 하나 또는 둘 | 넷 |
| 그리는 줄 | 셋 | 하나 또는 둘 | **둘.** 나머지 둘은 안 쓴다 |
| 계정 수 | 여럿 | 하나 | 하나 |
| 창 띄우기, 작업 이전, 자동 재개 | 한다 | 안 한다 | 안 한다 |

---

## 3. 데이터 계층

### 3-1. 접속 정보를 프로세스에서 읽는다

```
ClfDesktop/AntigravityUsage.swift    응답 해석과 접속 정보 캐내기 (순수 함수), 네트워크 경계
ClfDesktop/AntigravityReader.swift   읽고 OrgUsage 로 만든다
```

`AltInstance.scanInstances` 가 이미 `ps -A -o pid=,command=` 로 프로세스를
훑는다. 같은 방식이다. 명령을 돌리는 자리는 `Shell.run` 하나로 모았고 셋을
지킨다.

| 지키는 것 | 안 지키면 |
|---|---|
| 읽지 않는 stderr 파이프를 자식에게 안 준다 | `lsof` 가 경고를 64KB 넘게 뱉는 순간 자식이 write 에서 막히고 우리가 영원히 기다린다 |
| 실패와 빈 출력을 가른다 (`String?`) | 잘린 결과가 옳은 결과 행세를 해서 `앱이 꺼져 있다` 나 `창이 하나도 없다` 로 읽힌다 |
| 시한을 걸고 TERM 다음 KILL 로 올린다 | TERM 을 무시하는 자식이 영원히 산다 |

`UsageModel.refresh` 는 `refreshing` 을 세워 두고 `defer` 로 내린다. 이 함수가
안 돌아오면 그 `defer` 가 영영 안 돌고 **Claude 도 Codex 도 다시는 안 읽힌다.**
화면은 옛 숫자를 든 채 조용해서 사용자는 멈춘 줄도 모른다.

**우리 시한은 보장이 아니다.** 자식이 손자를 남기고 그 손자가 출력 파이프를
물려받았으면, 자식을 죽여도 파이프가 안 닫혀 읽기가 안 끝난다. `lsof` 가
정확히 그런 프로그램이라 (블록을 깨려고 자식을 띄운다) 그쪽은 `-S` 로 lsof
자신에게 시한을 건다. **그것이 진짜 방어다.**

`ps` 에는 서버가 **여럿** 보일 수 있다. 앱이 비정상 종료하면 자식 서버가 고아로
남기 때문이다. 죽은 쪽을 고르면 카드가 `꺼져 있다` 로 굳고 유일한 안내인 `켜기`
단추를 눌러도 안 고쳐진다. 그래서 후보를 새 것부터 늘어놓고 **LISTEN 포트가
잡히는 후보까지 내려간다.** 고아가 쌓여도 읽기 한 번이 길어지지 않게 셋에서
끊는다.

실행 파일이 그 서버인 줄만 잡아서 `/bin/sh -c ... language_server` 같은 줄에
속지 않는다. 대가가 하나 있다. **경로에 ` -` 가 든 앱은 못 알아본다.** `ps` 는
argv 를 공백 하나로 이어 붙이므로 `/apps -old/...` 와 `/bin/sh -c ...` 가 글자로
같은 모양이고, 둘 중 하나만 고를 수 있다. 못 알아보면 카드가 `꺼져 있다` 로
남을 뿐이지만, 반대로 하면 아무 줄이나 서버로 믿고 엉뚱한 토큰으로 두드린다.

```swift
/// 부를 주소. 포트는 시도할 차례대로 담는다. 큰 쪽이 평문 HTTP 다
public struct AntigravityEndpoint: Sendable, Equatable {
    public let ports: [Int]
    public let token: String
}

/// 캐내는 일은 순수 함수 둘로 갈라 테스트가 잠근다. 프로세스를 실제로
/// 돌리는 자리는 `LiveAntigravityProbe` 하나다
public func parseAntigravityProcess(psOutput: String) -> AntigravityProcess?
public func parseLoopbackPorts(lsof: String) -> [Int]
```

**`ps` 에 `-E` 를 주지 않는다.** 저쪽 함수는 환경변수까지 받으려고 `-E` 를
쓰는데, 우리가 필요한 값은 전부 명령줄 인자라 온 기계의 프로세스 환경변수를
우리 메모리로 들일 이유가 없다.

포트는 `lsof -nP -p <pid>` 의 `LISTEN` 줄에서 읽는다. 둘이 나오면 **큰 쪽**이
평문 HTTP 다. 실측이 그랬고, 작은 쪽으로 평문 요청을 보내면 서버가
`Client sent an HTTP request to an HTTPS server` 로 답해서 어느 쪽인지 알 수
있다. 큰 쪽부터 시도하고 틀리면 남은 포트로 넘어간다. 두 포트뿐이라 이것으로
끝난다.

HTTPS 쪽은 자체 서명 인증서라 검증을 꺼야 하는데, 검증을 끄는 코드를 두느니
평문 포트를 쓴다. 어차피 루프백이고 CSRF 토큰이 문을 지킨다.

### 3-2. Gemini 묶음만 읽는다

응답의 네 칸 중 둘만 쓴다.

| 버킷 | 쓰나 | `LimitKind` |
|---|---|---|
| `gemini-5h` | 쓴다 | `.session` |
| `gemini-weekly` | 쓴다 | `.weeklyAll` |
| `3p-5h` | 안 쓴다 | |
| `3p-weekly` | 안 쓴다 | |

**둘째 묶음은 Antigravity 안에서 Claude 나 GPT 모델을 골라 쓸 때만 닳는다.**
Antigravity 를 쓰는 이유가 Gemini 인 사람에게 그 두 줄은 영원히 100% 인
자리만 먹는다. 그리고 그 줄에 `Claude` 라고 적히면 바로 위의 진짜 Claude
계정 카드와 헷갈린다. 다른 주머니를 같은 이름으로 부르는 셈이다.

이 하나로 설계가 통째로 가벼워진다.

| 안 써도 되는 것 | 왜 |
|---|---|
| `LimitKind` 새 케이스 | 넷째 칸이 필요 없다. 셋 그대로다 |
| `LimitKind.allCases` 를 쓰는 자리 손보기 | 케이스가 안 늘어 기존 코드가 그대로 맞는다 |
| 카드의 묶음 머리글 | 줄이 둘뿐이라 어느 묶음인지 헷갈릴 일이 없다 |
| 막대 게이지 네 줄의 높이 계산 | 두 줄이라 Codex 와 같다 |

**둘째 묶음이 필요해지면** 그때 `LimitKind` 에 케이스를 더하고 카드에 머리글을
얹는다. 그 설계는 이 문서의 git 기록에 남아 있다. 지금 넣지 않는 이유는
"언젠가 쓸지도" 뿐이고, 그 값을 실제로 보고 싶다는 사람이 아직 없다.

### 3-3. 어느 묶음이 Gemini 인가

버킷 이름으로 고른다. `bucketId` 가 `gemini-` 로 시작하는 버킷을 가진 묶음이다.

`displayName` 으로 고르지 않는다. 사람에게 보이라고 있는 문구라 구글이 언제든
바꾼다. `bucketId` 는 프로토콜 쪽 이름이라 덜 흔들린다.

**못 찾으면 첫째 묶음으로 떨어진다.** 구글이 버킷 이름을 바꾸면 카드가 비는
대신 첫째 묶음이 뜬다. 네이티브 묶음이 먼저 오는 것이 지금 관측이고, 틀려도
빈 카드보다는 낫다. 값이 보이면 사용자가 이상한 것을 알아채지만, 빈 카드는
clf 가 고장 난 것으로만 보인다.

창은 `window` 필드(`5h`, `weekly`)로 가른다. 모르는 값이 오면 그 버킷을
건너뛴다.

떨어질 때도 `3p-` 묶음은 안 고른다. 다른 주머니 숫자에 `Gemini` 배지를 달아
내보내면 그냥 거짓말이다.

### 3-4. 없는 값과 못 읽는 값을 가른다

`remainingFraction` 이 **키째 없으면 0 으로 읽는다.** protobuf JSON 이 기본값을
안 싣기 때문이고, 그 전제가 틀리면 소진된 창이 통째로 사라져 카드가 옛 숫자를
내밀고 알림도 침묵한다.

**키가 있는데 못 읽는 값이면 그 버킷을 건너뛴다.** 문자열이나 null 이 오는
날까지 0 으로 읽으면 80% 남은 계정에 소진 알림이 나간다. 사라진 줄은 사용자가
이상한 것을 알아채지만 거짓 소진은 알아챌 방법이 없다.

### 3-5. 0% 와 100% 는 진짜 양 끝에서만

서버가 주는 잔여는 소수다. 그대로 반올림해 정수로 만들면 양 끝에서 거짓말이
나온다.

| 잔여 | 그냥 반올림하면 | 무엇이 틀리나 |
|---|---|---|
| 0.996 | 사용률 0 | 창이 돌고 있는데 `창 안 열림` 이라고 적는다 |
| 0.004 | 사용률 100 | 아직 쓸 수 있는데 **소진 알림이 나간다** |

그래서 조금이라도 썼으면 1 이상, 조금이라도 남았으면 99 이하로 묶는다. 0 과
100 은 잔여가 정확히 1 과 0 일 때만 나온다. 리셋 시각을 버릴지도 정수가 아니라
잔여 소수로 판정한다.

Claude 와 Codex 는 서버가 사용률을 정수로 줘서 이 갈래가 없다. 잔여를 뒤집는
이 공급자에만 있다.

### 3-6. 읽는 쪽

```swift
public struct AntigravityReader: Sendable {
    public var isInstalled: Bool    // Antigravity.app 이 있나
    public func read() async -> ProviderResult
}
```

`CodexReader` 와 같은 모양이다. 던지지 않고, 앱이 없으면 빈 결과다.
`ProviderResult` 는 그때 `CodexResult` 에서 이름만 바꾼 것이다. 계정 하나에
오류 갈래 둘이라는 모양이 둘 다 같아서 하나로 쓴다.

| 필드 | 값 |
|---|---|
| `uuid` | 상수 `antigravity`. 기계에 프로필이 하나라 그것으로 족하다 |
| `name` | `Antigravity` |
| `plan` | `GetUserStatus` 의 `planName` (`Pro`). 못 읽으면 nil |
| `isActive` | `false`. 활성 개념이 없다 |
| `provider` | `.antigravity` |

uuid 를 상수로 두는 이유. 이 값은 `hidden` 과 `order` 설정이 걸리는 열쇠다.
앱이 꺼져 있어도, 한 번도 안 켰어도 같은 값이라야 **숨김과 순서가 안 풀린다.**
`installation_id` 파일을 읽는 길도 있지만 앱을 한 번도 안 켠 기계에는 그 파일이
없고, 없는 동안 카드가 사라진다. Antigravity 는 기계에 프로필이 하나라 상수로
족하다.

### 3-7. 앱이 꺼져 있을 때

지난 값을 남기고 이유를 적는다. `mergeKeepingLastGood` 과 `isStale` 이 이미
그 일을 한다. 문구만 이 경우에 맞춘다.

```
갱신 못 함. Antigravity 가 꺼져 있다. 켜면 다시 읽는다
```

**막대에는 안 올린다.** 여기서 Claude 와 갈린다. Claude 의 낡은 값은 회선이
돌아오면 몇 분 안에 스스로 고쳐지는 값이라 막대에 두어도 곧 참이 된다.
Antigravity 의 낡은 값은 사람이 앱을 켜기 전에는 며칠이고 그대로다. 갱신될 수
없는 숫자를 "지금" 을 말하는 자리에 두면 막대 전체를 못 믿게 된다.

```swift
extension OrgUsage {
    /// 다시 읽을 길이 지금 없는 값인가. 막대는 이런 값을 안 올린다.
    public var isFrozen: Bool { isStale && provider == .antigravity }
}
```

`Preferences.barOrgs` 가 지금 `hasUsage` 로 거르는 자리에 이것을 더한다.
팝오버와 설정 목록에는 그대로 남는다. 거기서는 왜 낡았는지까지 말할 수 있다.

---

## 4. 화면

시안: [antigravity-card-mockup.html](antigravity-card-mockup.html)

### 4-1. Codex 카드와 같은 모양이다

`OrgCard` 를 그대로 쓴다. 줄이 둘이라 `rowKinds` 가 이미 하는 일이다
([18 문서](18-codex-usage.md) 4-1절). 새 레이아웃이 없다.

```
Antigravity   [Pro] [Gemini]            앞으로 꺼내기

  5시간    [====        ]  38%
           3시간 12분 뒤 리셋
  주간     [==          ]  15%
           6일 뒤 리셋
```

이름 옆 회색 `Gemini` 배지 하나가 **이 숫자가 어느 주머니의 것인지** 말한다.
Antigravity 에 주머니가 둘인데 하나만 그리므로 그 사실을 숨기지 않는다.
배지 하나면 되는 말이라 머리글 줄을 따로 두지 않는다. 회색인 것은 파랑을
플랜 배지가 이미 쓰고 있고 빨강과 노랑과 초록은 등급이 쓰기 때문이다.

주간 라벨은 `주간` 이다. Codex 와 같은 이유로 `주간 전체` 라고 쓰지 않는다.
전체가 아닌 것이 이 카드에는 없다.

### 4-2. 막대

Codex 의 `plus` 플랜과 똑같다. 숫자 두 줄에 게이지 두 줄이다.

```
T40  91%  ::::::::::::::::::    An  38%  ::::::::
     84%  ::::::::::::::            15%  :::
          ::::::::::::::::::
```

계정 코드는 `An` 이다. 계정이 하나면 Codex 처럼 앱 아이콘으로 바꾼다
([18 문서](18-codex-usage.md) 4-2절과 같은 규칙이고 번들만 다르다).

### 4-3. 카드의 단추

Codex 와 같다. Antigravity 앱을 앞으로 꺼낸다. 앱이 안 깔려 있으면 단추가
없다. 앱이 꺼져 있으면 단추가 `켜기` 가 되고, 누르면 앱을 띄운다. **이것이
이 카드에서 유일하게 값을 되살리는 길이라 단추가 곧 안내다.**

### 4-4. 차례

```
Claude 활성 -> Claude 이름순 -> Codex -> Antigravity
```

들어온 차례다. 기존 사용자의 화면이 위에서부터 그대로 유지된다. 순서를
정했으면 그쪽이 이긴다. `Preferences.ordered` 의 정렬 열쇠에 `provider` 순위를
하나 더 둔다.

### 4-5. 알림

`UsageAlerts` 가 그대로 돈다. 한 자리만 고쳤다. `한도 전부 소진` 을 판정할 때
`LimitKind.allCases`(셋)가 아니라 **이번에 읽힌 칸 수**를 센다. 그러지 않으면
칸이 둘뿐인 공급자는 다 막혀도 그 말을 영영 못 듣는다.

단 **칸이 하나면 `전부` 라고 말하지 않는다.** 읽힌 칸은 그 공급자에 있는 칸이
아니라 이번에 해석된 칸이라, 주간 줄이 사라진 읽기에서 5시간 한 칸이 전부
행세를 한다. 주간이 80% 남아 있어도 전부 소진이라고 말하게 된다.

`others` 는 이미 같은 공급자만 넘긴다 ([18 문서](18-codex-usage.md) 4-5절).
Antigravity 계정은 하나라 넘어갈 곳이 없고, 그러면 `spare` 가 nil 이라 덧붙는
문장이 안 붙는다. 그대로 맞는 동작이다.

### 4-6. 손대지 않는 자리

인스턴스 띄우기, 작업 이전, 양쪽에 두기, 자동 재개, 포커스 밑줄. 전부 Claude
세션 형식과 Claude 앱 위에 서 있다. 이미 `provider == .claude` 로 걸러 둔
자리라 [18 문서](18-codex-usage.md) 4-6절의 표가 그대로 맞는다. 새로 거를
자리는 없다.

---

## 5. clfctl

```
  Antigravity  (Pro, Gemini)
    5시간      [########............] 잔여  62%   3시간 12분 뒤 리셋
    주간       [###.................] 잔여  85%   6일 뒤 리셋
```

JSON 에는 `provider: "antigravity"` 가 붙는다. 칸 이름은 `session` 과
`weekly_all` 로 앞의 둘과 같다.

앱이 꺼져 있으면 그 줄을 적는다. 값을 못 읽는 것과 앱이 꺼진 것은 다르고,
사용자가 할 일이 다르다.

```
  Antigravity
    Antigravity 가 꺼져 있다. 켜면 읽는다
```

---

## 6. 1차에서 빼는 것

| 뺀 것 | 왜 | 언제 넣나 |
|---|---|---|
| Claude/GPT 묶음 (`3p-5h`, `3p-weekly`) | Antigravity 안에서 그 모델을 골라 쓸 때만 닳는 별도 주머니다. Gemini 를 쓰는 사람에게는 영원히 100% 인 두 줄이고, `Claude` 라는 글자가 진짜 Claude 카드와 헷갈린다 | 그 주머니가 실제로 닳는 사람이 나오면. `LimitKind` 에 케이스를 더하고 카드에 묶음 머리글을 얹는다 |
| 크레딧 (`availablePromptCredits`, `availableFlowCredits`) | 시간 창과 단위가 다르다. 500 과 100 이 무슨 뜻인지 관측으로 확인하지 못했다 | 값이 줄어드는 것을 보고 뜻이 분명해지면. `SpendUsage` 자리가 비어 있다 |
| 앱을 우리가 띄워서 읽기 | `language_server` 는 앱이 관리하는 무거운 프로세스다. 사용량을 보려고 남의 앱 프로세스를 띄우는 것은 이 저장소가 지켜온 선(읽기만 한다)을 넘는다 | 하지 않는다 |
| HTTPS 포트 | 자체 서명이라 검증을 꺼야 한다. 루프백 평문으로 충분하다 | 평문 포트가 사라지면 |
| 토큰 갱신, 로그인 | Claude, Codex 와 같은 자세 | 하지 않는다 |
| 계정 여럿 | Antigravity 는 기계에 프로필이 하나다 | 여러 프로필이 생기면 |

---

## 7. 테스트로 잠글 것

파일과 프로세스와 네트워크를 뺀 나머지가 순수 함수다.

| 테스트 | 잡는 것 |
|---|---|
| `parseAntigravityUsage` Pro 응답 | Gemini 두 칸만 남는다. `3p` 는 안 들어온다 |
| 잔여를 사용률로 | `remainingFraction 0.38` 이 `percentUsed 62` 가 된다. 반올림 경계 |
| `remainingFraction == 1` | `resetsAt` 이 nil 이다. 흐르는 시각을 안 믿는다 |
| 묶음 차례가 뒤집힌 응답 | `3p` 가 먼저 와도 `gemini-` 버킷을 고른다 |
| `gemini-` 버킷이 없는 응답 | 첫째 묶음으로 떨어지고 빈 카드가 안 된다 |
| 모르는 `window` 값 | 그 버킷만 건너뛴다 |
| `groups` 가 빈 응답 | 보여줄 것이 없는 계정이다 |
| `parseAntigravityEndpoint` | ps 한 줄에서 토큰을, lsof 에서 포트 둘을 캐낸다. 큰 쪽이 먼저다 |
| 프로세스가 없는 ps | nil 이다. 앱이 꺼진 것이다 |
| `isFrozen` | 낡은 Antigravity 는 참, 낡은 Claude 는 거짓 |
| `barOrgs` | 낡은 Antigravity 가 막대에서 빠진다. 팝오버 목록에는 남는다 |
| 기본 차례 | Claude -> Codex -> Antigravity |
| `BarText.codes` | `Antigravity` 가 `An` 이다 |
