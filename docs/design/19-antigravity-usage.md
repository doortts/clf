# 19. Antigravity 계정 사용량

Claude 와 Codex 카드 옆에 Google Antigravity 카드를 둔다. 5시간 창과 주간 창,
리셋까지 남은 시간, 플랜 배지, 메뉴바 막대까지 같은 자리에 같은 규칙으로 그린다.

**할 수 있다. 다만 Antigravity 앱이 떠 있는 동안만이다.** 2026-09-16 에 이
기계에서 확인했다. 앱 버전 2.12.2, 번들 `com.google.antigravity`. 근거는 1절.

앞의 둘과 갈리는 대목이 이것 하나다. Claude 와 Codex 는 디스크의 토큰으로
서버에 직접 물어서 앱이 꺼져 있어도 읽힌다. Antigravity 는 토큰이 디스크에
없고, 읽을 창구가 앱이 띄우는 로컬 서버뿐이다.

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
  ],
  "description": "Within each group, models share a weekly limit and a 5-hour limit. ..."
}}
```

**모델 묶음이 둘이고 묶음마다 창이 둘이라 칸이 넷이다.** Claude 는 셋,
Codex 는 하나 또는 둘이었다. 여기가 화면에서 가장 크게 갈린다 (4절).

그리고 **서버가 주는 값이 잔여다.** `remainingFraction` 은 0 에서 1 사이
소수이고 1 이 가득 남은 것이다. Claude 와 Codex 는 사용률을 주고 우리가
잔여를 파생시켰는데 여기는 방향이 반대다. `percentUsed` 를 우리가 파생시킨다.

플랜은 다른 RPC 에 있다. `GetUserStatus` 가 `planName: "Pro"`,
`teamsTier: "TEAMS_TIER_PRO"`, 그리고 크레딧(`availablePromptCredits`,
`availableFlowCredits`, `monthlyPromptCredits`)을 준다.

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
| 잔여가 실제로 줄어드는 모습 | 관측 못 했다. 읽는 동안 네 칸이 전부 1 이었다 | 값의 뜻은 필드 이름과 방향이 분명하다. 줄어드는 모습은 쓰면서 확인한다 |
| 플랜마다 묶음 구성이 같은가 | `Pro` 하나만 봤다 | 묶음과 창을 **응답이 준 대로** 읽는다. 묶음이 셋이 되어도 죽지 않게 한다 (3-2절) |
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
| 창 | 셋 | 하나 또는 둘 | **넷 (묶음 둘 곱하기 창 둘)** |
| 계정 수 | 여럿 | 하나 | 하나 |
| 창 띄우기, 작업 이전, 자동 재개 | 한다 | 안 한다 | 안 한다 |

---

## 3. 데이터 계층

### 3-1. 접속 정보를 프로세스에서 읽는다

```
ClfDesktop/AntigravityProbe.swift    ps 에서 포트와 토큰을 캐낸다
ClfDesktop/AntigravityUsage.swift    응답 해석 (순수 함수)
ClfDesktop/AntigravityReader.swift   읽고 OrgUsage 로 만든다
```

`AltInstance.scanInstances` 가 이미 `ps -A -o pid=,command=` 로 프로세스를
훑는다. 같은 방식이다.

```swift
public struct AntigravityEndpoint: Sendable, Equatable {
    public let port: Int
    public let token: String
}

/// ps 한 줄에서 접속 정보를 캐낸다. 순수 함수라 테스트가 잠근다.
public func parseAntigravityEndpoint(psOutput: String, lsof: String) -> AntigravityEndpoint?
```

**`ps` 에 `-E` 를 주지 않는다.** 저쪽 함수는 환경변수까지 받으려고 `-E` 를
쓰는데, 우리가 필요한 값은 전부 명령줄 인자라 온 기계의 프로세스 환경변수를
우리 메모리로 들일 이유가 없다.

포트는 `lsof -nP -p <pid>` 의 `LISTEN` 줄에서 읽는다. 둘이 나오면 **큰 쪽**이
평문 HTTP 다. 실측이 그랬고, 작은 쪽으로 평문 요청을 보내면 서버가
`Client sent an HTTP request to an HTTPS server` 로 답해서 어느 쪽인지 알 수
있다. 그 답을 보고 다른 포트로 한 번 더 가는 대신 큰 쪽부터 시도하고,
틀리면 남은 포트로 넘어간다. 두 포트뿐이라 이것으로 끝난다.

HTTPS 쪽은 자체 서명 인증서라 검증을 꺼야 하는데, 검증을 끄는 코드를 두느니
평문 포트를 쓴다. 어차피 루프백이고 CSRF 토큰이 문을 지킨다.

### 3-2. 네 칸을 기존 모델에 앉힌다

`LimitKind` 에 케이스 하나를 더한다.

```swift
public enum LimitKind: String, Sendable, CaseIterable {
    case session                          // 5시간
    case sessionScoped = "session_scoped" // 새로 는 것. 모델 묶음 하나의 5시간
    case weeklyAll = "weekly_all"
    case weeklyScoped = "weekly_scoped"
}
```

`scoped` 는 이 저장소에서 이미 "모델 일부에만 걸리는 창" 을 뜻한다
(Claude 의 `weekly_scoped` 가 Fable 창이다). Antigravity 의 둘째 묶음이 바로
그 뜻이라 말이 그대로 맞는다.

| 버킷 | `LimitKind` |
|---|---|
| `gemini-5h` | `.session` |
| `gemini-weekly` | `.weeklyAll` |
| `3p-5h` | `.sessionScoped` |
| `3p-weekly` | `.weeklyScoped` |

**묶음 이름이 아니라 차례로 가른다.** 응답이 준 첫째 묶음이 기본 칸을 쓰고
둘째 묶음이 `scoped` 칸을 쓴다. `Gemini` 라는 문자열로 가르면 구글이 묶음
이름을 바꾸는 날 카드가 빈다. 묶음이 셋 이상이면 셋째부터는 버린다. 담을
칸이 없고, 없는 것을 지어내느니 안 그리는 것이 낫다.

창은 `window` 필드(`5h`, `weekly`)로 가른다. 모르는 값이 오면 그 버킷을
건너뛴다.

### 3-3. 케이스가 늘면 같이 고쳐야 하는 자리

`LimitKind.allCases` 가 셋이라고 전제한 코드가 있다. 넷이 되면 **Claude 가
조용히 틀린다.**

| 자리 | 지금 | 고칠 것 |
|---|---|---|
| `UsageAlerts.windowAlerts` 의 `all` 판정 | `exhausted.count == LimitKind.allCases.count` | `org.rowKinds.count` 와 견준다. 안 고치면 Claude 는 셋이 다 막혀도 `한도 전부 소진` 이 영영 안 뜬다 |
| `UsageAlerts.windowAlerts` 의 순회 | `LimitKind.allCases` | `org.rowKinds`. 없는 칸을 돌 이유가 없다 |
| `clfctl` 의 표 | `LimitKind.allCases` | `org.rowKinds` |
| `OrgCard`, `SegmentBlock`, `BarOrgView` | 이미 `org.rowKinds` 다 | 그대로 |

`rowKinds` 는 [18 문서](18-codex-usage.md) 4-1절에서 Codex 때문에 들어온
것인데, 마침 이 일에 그대로 쓰인다. Claude 는 지금처럼 넷 중 셋만 돌게
`provider` 로 가른다.

### 3-4. 읽는 쪽

```swift
public struct AntigravityReader: Sendable {
    public var isInstalled: Bool    // /Applications/Antigravity.app 이 있나
    public func read() async -> AntigravityResult
}
```

`CodexReader` 와 같은 모양이다. 던지지 않고, 앱이 없으면 빈 결과다.

| 필드 | 값 |
|---|---|
| `uuid` | `~/.gemini/antigravity/installation_id`. 계정 식별자가 아니지만 **이 기계에서 안 바뀌는 값**이면 된다. `hidden` 과 `order` 가 이것으로 걸린다 |
| `name` | `Antigravity` |
| `plan` | `GetUserStatus` 의 `planName` (`Pro`). 못 읽으면 nil |
| `isActive` | `false`. 활성 개념이 없다 |
| `provider` | `.antigravity` |

`installation_id` 는 앱이 꺼져 있어도 읽힌다. 그래서 **앱이 꺼진 상태에서도
카드 자리와 설정 줄이 유지된다.** 앱이 뜨고 질 때마다 uuid 가 바뀌면 그때마다
숨김 설정이 풀리고 카드가 새것처럼 나타난다.

### 3-5. 앱이 꺼져 있을 때

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

### 4-1. 카드에 묶음 머리글을 둔다

네 줄을 한 열로 세우면 어느 줄이 어느 묶음인지 알 수 없다. 라벨에 묶음을
적으면 (`Claude/GPT 5시간`) 58점짜리 라벨 칸을 두 배로 넘긴다.

그래서 묶음마다 머리글 한 줄을 얹는다. 라벨은 `5시간`, `주간` 그대로 짧게
남고 칸 폭도 그대로다.

```
Antigravity            [Pro]              앞으로 꺼내기

  Gemini
    5시간    [====        ]  38%
             3시간 12분 뒤 리셋
    주간     [==          ]  15%
             6일 뒤 리셋
  Claude/GPT
    5시간    [========    ]  71%
             3시간 12분 뒤 리셋
    주간     [===         ]  22%
             6일 뒤 리셋
```

머리글은 캡션 크기에 보조색이다. 게이지보다 뒤로 물러나야 숫자가 먼저 읽힌다.

머리글 문구는 응답의 `displayName` 을 그대로 쓰지 않는다. `Claude and GPT
models` 는 카드 폭에 길고, 이 카드에서 `Claude` 는 옆의 Claude 계정 카드와
헷갈린다. 우리가 짧게 적는다.

| 응답 | 카드 |
|---|---|
| `Gemini Models` | `Gemini` |
| `Claude and GPT models` | `Claude/GPT` |

모르는 묶음 이름이 오면 `displayName` 에서 `Models` 를 떼고 그대로 쓴다.

### 4-2. 막대는 숫자 두 줄에 게이지 네 줄

게이지 네 줄은 `(3 + 0.5 곱하기 2) 곱하기 4 + 2 곱하기 3 = 22점`이다. 숫자
두 줄이 11점씩 22점이라 **두 열의 높이가 정확히 같다.** 메뉴바 24점에 들어간다.

숫자 두 줄에는 **묶음을 가로질러 가장 빡빡한 5시간 하나와 가장 빡빡한 주간
하나**를 적는다. 묶음 하나를 골라 적으면 다른 묶음이 막혀도 막대가 모른다.
줄의 뜻(`위가 5시간, 아래가 주간`)은 그대로라 눈이 따라간다.

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

`UsageAlerts` 가 그대로 돈다. 고칠 것은 3-3절의 `allCases` 자리뿐이다.

`others` 는 이미 같은 공급자만 넘긴다 ([18 문서](18-codex-usage.md) 4-5절).
Antigravity 계정은 하나라 넘어갈 곳이 없고, 그러면 `spare` 가 nil 이라 덧붙는
문장이 안 붙는다. 그대로 맞는 동작이다.

`.sessionScoped` 하나만 소진일 때의 덧말은 `.weeklyScoped` 와 같다.
`다른 모델은 쓸 수 있습니다.` 묶음이 둘이라는 사실이 그대로 그 말이다.

### 4-6. 손대지 않는 자리

인스턴스 띄우기, 작업 이전, 양쪽에 두기, 자동 재개, 포커스 밑줄. 전부 Claude
세션 형식과 Claude 앱 위에 서 있다. 이미 `provider == .claude` 로 걸러 둔
자리라 [18 문서](18-codex-usage.md) 4-6절의 표가 그대로 맞는다. 새로 거를
자리는 없다.

---

## 5. clfctl

```
  Antigravity  (Pro)
    Gemini
    5시간      [########............] 잔여  62%   3시간 12분 뒤 리셋
    주간       [###.................] 잔여  85%   6일 뒤 리셋
    Claude/GPT
    5시간      [###.................] 잔여  29%   3시간 12분 뒤 리셋
    주간       [####................] 잔여  78%   6일 뒤 리셋
```

JSON 에는 `provider: "antigravity"` 와 네 칸이 들어간다. 묶음은 칸 이름
(`session`, `session_scoped`, `weekly_all`, `weekly_scoped`)이 이미 말한다.

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
| 크레딧 (`availablePromptCredits`, `availableFlowCredits`) | 시간 창과 단위가 다르다. Enterprise 예산 줄과 같은 자리인데, 이 계정에서 500 과 100 이 무슨 뜻인지 관측으로 확인하지 못했다 | 값이 줄어드는 것을 보고 뜻이 분명해지면. `SpendUsage` 자리가 비어 있다 |
| 묶음 셋 이상 | 관측 없음. 담을 칸이 없다 | 실제로 오면. 그때는 `LimitKind` 를 늘리는 대신 칸 이름을 자유 문자열로 바꿀 때다 |
| 앱을 우리가 띄워서 읽기 | `language_server` 는 앱이 관리하는 무거운 프로세스다. 사용량을 보려고 남의 앱 프로세스를 띄우는 것은 이 저장소가 지켜온 선(읽기만 한다)을 넘는다 | 하지 않는다 |
| HTTPS 포트 | 자체 서명이라 검증을 꺼야 한다. 루프백 평문으로 충분하다 | 평문 포트가 사라지면 |
| 토큰 갱신, 로그인 | Claude, Codex 와 같은 자세 | 하지 않는다 |
| 계정 여럿 | Antigravity 는 기계에 프로필이 하나다 | 여러 프로필이 생기면 |

---

## 7. 테스트로 잠글 것

파일과 프로세스와 네트워크를 뺀 나머지가 순수 함수다.

| 테스트 | 잡는 것 |
|---|---|
| `parseAntigravityUsage` Pro 응답 | 네 버킷이 네 칸에 앉는다. 차례로 갈린다 |
| 잔여를 사용률로 | `remainingFraction 0.38` 이 `percentUsed 62` 가 된다. 반올림 경계 |
| `remainingFraction == 1` | `resetsAt` 이 nil 이다. 흐르는 시각을 안 믿는다 |
| 묶음 하나뿐인 응답 | `scoped` 칸이 비고 죽지 않는다 |
| 묶음 셋인 응답 | 셋째를 버리고 죽지 않는다 |
| 모르는 `window` 값 | 그 버킷만 건너뛴다 |
| `groups` 가 빈 응답 | 보여줄 것이 없는 계정이다 |
| `parseAntigravityEndpoint` | ps 한 줄에서 토큰을, lsof 에서 포트 둘을 캐낸다. 큰 쪽이 먼저다 |
| 프로세스가 없는 ps | nil 이다. 앱이 꺼진 것이다 |
| `isFrozen` | 낡은 Antigravity 는 참, 낡은 Claude 는 거짓 |
| `barOrgs` | 낡은 Antigravity 가 막대에서 빠진다. 팝오버 목록에는 남는다 |
| 알림 `all` 판정 | 칸이 넷이 되어도 Claude 는 셋으로 판정한다 |
| 기본 차례 | Claude -> Codex -> Antigravity |
| `BarText.codes` | `Antigravity` 가 `An` 이다 |
