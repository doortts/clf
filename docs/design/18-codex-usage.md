# 18. Codex 계정 사용량

Claude 계정 카드 옆에 ChatGPT Codex 계정 카드를 같은 모양으로 둔다. 5시간 창과
주간 창, 리셋까지 남은 시간, 플랜 배지, 메뉴바 막대까지 Claude 와 같은 자리에
같은 규칙으로 그린다.

**할 수 있다.** 2026-09-11 에 이 기계에서 직접 확인했다. 근거는 1절.
같은 날 구현했다. `CodexUsage.swift`, `CodexReader.swift` 와 `CodexUsageTests`.

---

## 1. 가능 여부: 확인한 것과 못 한 것

### 1-1. 토큰은 파일에 그대로 있다

Codex CLI 와 Codex 데스크톱 앱은 `~/.codex/auth.json` 하나를 같이 쓴다.
Claude 앱처럼 safe storage 로 감싸지 않았다. 권한 `0600` 인 평문 JSON 이다.

```json
{
  "auth_mode": "chatgpt",
  "tokens": {
    "id_token": "eyJ...",
    "access_token": "eyJ...",
    "refresh_token": "rt.1...",
    "account_id": "c7bbb1fc-..."
  },
  "last_refresh": "2026-09-11T04:40:35Z"
}
```

Keychain 도 복호화도 필요 없다. 파일 하나 읽으면 끝이다. Claude 쪽에서 가장
길었던 [10 문서](10-desktop-usage.md) 2절이 여기서는 통째로 없다.

### 1-2. Usage API 가 있고 토큰을 안 쓴다

```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <access_token>
ChatGPT-Account-Id: <account_id>
```

Codex CLI 의 `/status` 가 부르는 곳이다. 추론 요청이 아니라 사용량을 소모하지
않는다. 실제 응답(이 계정, 2026-09-11):

```json
{
  "plan_type": "prolite",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window":   {"used_percent": 9, "limit_window_seconds": 604800,
                         "reset_after_seconds": 585945, "reset_at": 1789706432},
    "secondary_window": null
  },
  "additional_rate_limits": [
    {"limit_name": "GPT-5.3-Codex-Spark",
     "rate_limit": {"primary_window":   {"used_percent": 0, "limit_window_seconds": 18000, ...},
                    "secondary_window": {"used_percent": 0, "limit_window_seconds": 604800, ...}}}
  ],
  "credits": {"has_credits": false, "unlimited": false, "balance": "0"},
  "rate_limit_reached_type": null
}
```

Claude 의 `limits` 배열과 뜻이 같다. `used_percent` 는 사용률, `reset_at` 은
epoch 초, `limit_window_seconds` 가 창 길이다. **창 길이를 서버가 준다.** Claude
는 안 줘서 종류로 짐작했는데 (`LimitKind.window`) 여기는 짐작할 필요가 없다.

### 1-3. 창의 구성은 플랜이 정한다

같은 기계의 Codex 세션 기록(`~/.codex/sessions/**/rollout-*.jsonl` 의
`token_count` 이벤트)에는 9월 4일자 `plus` 플랜 응답이 남아 있다.

```json
"rate_limits": {"primary":   {"used_percent": 49.0, "window_minutes": 300,   "resets_at": 1788462824},
                "secondary": {"used_percent": 93.0, "window_minutes": 10080, "resets_at": 1788840284},
                "plan_type": "plus"}
```

| 플랜 | primary | secondary |
|---|---|---|
| `plus`, `pro`, `team` | 5시간 (300분) | 주간 (10080분) |
| `prolite` | 주간 | 없음 |

**자리(primary/secondary)로 읽으면 틀린다.** `prolite` 의 primary 는 주간이다.
창 길이로 읽는다. 18000초면 5시간 줄, 604800초면 주간 줄이다.

### 1-4. 세션 기록으로 읽는 길은 안 쓴다

위 `rollout-*.jsonl` 은 Codex 를 실제로 쓸 때만 갱신된다. 며칠 안 쓰면 그대로
낡는다. Claude 에서 응답 헤더 편승을 버린 이유([10 문서](10-desktop-usage.md)
3절)와 같다. 메뉴바가 주기적으로 갱신해야 하므로 API 를 부른다.

### 1-5. 확인하지 못한 것

| 무엇 | 지금 아는 것 | 대처 |
|---|---|---|
| Usage API 의 429 정책 | 관측 없음. 한 번 불렀다 | Claude 와 같은 `ReadGate` 뒤에 둔다. 429 가 오면 같은 방식으로 물러난다 |
| `access_token` 수명 | JWT 의 `exp` 를 우리는 안 푼다. CLI 는 `last_refresh` 가 8일 넘으면 갱신한다 | 401 이면 "Codex 에서 한 번 쓰면 갱신된다" 고 적는다. 우리가 갱신하지 않는다. Claude 와 같은 자세다 |
| Codex 데스크톱 앱이 `auth.json` 을 갱신하는지 | `~/.codex` 를 같이 쓰는 것은 확인. 갱신 주체는 미확인 | 위와 같다. 만료되면 그 사실만 말한다 |
| `additional_rate_limits` 의 뜻 | 모델별 별도 한도 (Spark). Claude 의 `weekly_scoped` 와 비슷 | 1차에서 안 그린다. 6절 |

---

## 2. 무엇이 같고 무엇이 다른가

| | Claude | Codex |
|---|---|---|
| 토큰 자리 | `config.json` 의 safe storage 암호문. Keychain 키 필요 | `~/.codex/auth.json` 평문 |
| 계정 수 | 앱이 캐시한 계정 전부 | **하나.** 파일에 계정이 하나다 |
| 계정 이름 | claude.ai 세션으로 조직 이름을 얻는다 | 없다. 응답에 이메일과 플랜만 있다 |
| 활성 계정 | 앱 로그와 쿠키로 판정 | 개념이 없다. 그 하나가 곧 활성이다 |
| 창 | `limits` 배열. 종류(`kind`)로 구별. 셋 고정 | 창 길이로 구별. 플랜마다 하나 또는 둘 |
| 사용률 0 인 창 | `resets_at` 이 없다 | `reset_at` 이 온다. **지금 + 창 길이**라 뜻이 없다 |
| 창 띄우기 | 계정별 인스턴스 ([13 문서](13-multi-instance.md)) | 앱이 멀티 윈도우를 이미 지원한다. 우리가 할 일 없다 |
| 작업 이전, 공유, 자동 재개 | 한다 | **안 한다.** Claude 세션 형식이다 |

계정이 하나라는 것이 가장 큰 차이다. Codex 에서 둘째 계정을 쓰려면 `CODEX_HOME`
을 다른 디렉토리로 주고 CLI 를 따로 띄워야 하는데, 데스크톱 앱은 `~/.codex`
만 본다. 둘째 디렉토리의 토큰은 그 CLI 를 돌리지 않으면 갱신될 길이 없다.
그래서 1차는 `~/.codex` 하나만 읽는다. 6절.

---

## 3. 데이터 계층

### 3-1. 모델은 그대로 쓴다

`OrgUsage` 에 필드 하나만 는다.

```swift
public enum Provider: String, Sendable, Codable { case claude, codex }

public struct OrgUsage {
    public let provider: Provider     // 기본값 .claude. 기존 생성 코드는 그대로 컴파일된다
    ...
}
```

`limits: [LimitKind: UsageLimit]` 를 그대로 쓴다. Codex 창을 여기에 넣는다.

| `limit_window_seconds` | `LimitKind` |
|---|---|
| 86400 미만 | `.session` |
| 86400 이상 | `.weeklyAll` |

`.weeklyScoped` 는 비워 둔다. 카드가 세 줄을 고정으로 그리는 자리에서 Codex 는
있는 줄만 그린다 (4절).

`LimitKind.window` 는 그대로 맞는다. 5시간 창이 `.session` 에, 7일 창이
`.weeklyAll` 에 들어가므로 리셋 진행률 계산이 어긋나지 않는다. 서버가 준 창
길이를 따로 담지 않는다. 담을 이유가 생기면 그때 `UsageLimit` 에 넣는다.

`percentUsed`, `resetsAt`, `band`, `binding`, 알림 판정, 갱신 주기 지문
(`RefreshPacer`)이 전부 이 모델 위에 있어서 **Codex 줄은 들어가는 순간
Claude 줄과 같은 대우를 받는다.** 이것이 모델을 새로 만들지 않는 이유다.

### 3-2. 라벨만 갈린다

```swift
extension LimitKind {
    public func label(for provider: Provider) -> String
}
```

| | Claude | Codex |
|---|---|---|
| `.session` | `5시간` | `5시간` |
| `.weeklyAll` | `주간 전체` | `주간` |
| `.weeklyScoped` | `주간 Fable` | (없음) |

Codex 카드에 `주간 전체` 라고 쓰면 "전체가 아닌 것" 이 있어야 하는데 없다.
`alertLabel` 은 이미 `주간 한도` 라 그대로 둔다.

### 3-3. 읽는 쪽

```
ClfDesktop/CodexReader.swift        auth.json 읽기, 스냅샷 조립
ClfDesktop/CodexUsage.swift         응답 해석 (순수 함수), 창 길이 -> LimitKind
```

`CodexReader.read()` 는 `[OrgUsage]` 하나를 돌려준다. 계정이 하나라 스냅샷을
따로 만들 것이 없다.

```swift
public struct CodexReader: Sendable {
    public static let defaultHome = ~/.codex
    public var isInstalled: Bool          // auth.json 이 있나
    public func read(now: Date) async -> CodexResult   // 던지지 않는다. 없으면 빈 배열
}
```

| 필드 | 값 |
|---|---|
| `uuid` | `tokens.account_id`. UUID 라 `hidden`, `order` 설정에 그대로 걸린다 |
| `name` | `Codex`. 응답의 이메일은 쓰지 않는다. 카드 폭 312 에 이메일은 길고, 메뉴바 코드가 `Co` 로 떨어지는 쪽이 낫다 |
| `plan` | `plan_type` 그대로 (`prolite`, `plus`, `pro`, `team`) |
| `isActive` | `false`. 활성 개념이 없다. 정렬은 4-4절 |
| `provider` | `.codex` |

`used_percent == 0` 인 창은 `resetsAt` 을 `nil` 로 둔다. 서버가 주는 값이
지금 + 창 길이라 "5시간 뒤 리셋" 으로 읽히는데 그건 타이머가 안 걸린 창이다.
Claude 와 같은 규칙으로 `창 안 열림` 이 뜬다.

`UsageFetching` 과 별개의 작은 프로토콜을 둔다. Claude 쪽 프로토콜에 메서드를
얹으면 가짜 구현 전부가 그 메서드를 알아야 한다.

```swift
public protocol CodexUsageFetching: Sendable {
    func usage(token: String, accountID: String) async throws -> CodexReport
}
```

오류는 `UsageFetchError` 를 그대로 쓴다. `throttled`, `offline` 판정이 같아야
`ReadGate` 와 `RefreshPacer` 가 한 자리에서 두 공급자를 다룬다.

### 3-4. 합치는 자리

`UsageModel.refresh` 가 둘을 읽고 이어 붙인다.

```swift
let claude = try? await reader.read(names: cachedNames)     // Claude 앱이 없으면 nil
let codex  = await codexReader.read()                         // auth.json 이 없으면 빈 배열
guard claude != nil || !codex.orgs.isEmpty else { failure = ...; return }
known = mergeKeepingLastGood(fresh: (claude?.knownOrgs ?? []) + codex.orgs, previous: known)
```

`DesktopReader.read` 는 Claude 앱이 없으면 던진다. 지금은 그것이 곧 앱의 실패다.
Codex 가 들어오면 **한쪽이 없어도 다른 쪽은 그려야 한다.** Claude 없이 Codex
만 쓰는 사람에게 "Claude 앱을 못 읽는다" 는 말은 오류가 아니라 사실이다.

`throttled` 와 `offline` 은 둘의 OR 다. `readAt` 은 둘 중 성공한 쪽 시각이다.

---

## 4. 화면

시안: [codex-card-mockup.html](codex-card-mockup.html)

### 4-1. 카드는 같은 카드다

`OrgCard` 를 그대로 쓴다. Codex 카드가 다른 곳은 셋이다.

| 자리 | Claude | Codex |
|---|---|---|
| 줄 수 | `LimitKind.allCases` 셋 고정. 없는 줄은 `?` | **있는 줄만.** `prolite` 는 주간 한 줄, `plus` 는 두 줄 |
| 이름 옆 배지 | 플랜(`team`), `기본`, 노란 점 | 플랜(`prolite`)만 |
| 오른쪽 단추 | `새 창` / `앞으로 꺼내기` (인스턴스) | `앞으로 꺼내기`. Codex 앱을 앞으로 (`NSWorkspace`, 번들 `com.openai.codex`). 없으면 단추 없음 |

없는 줄을 `?` 로 그리지 않는 이유. Claude 의 `?` 는 "있어야 하는데 못 읽었다"
는 뜻이다. `prolite` 의 5시간 줄은 못 읽은 것이 아니라 없는 것이다. 없는 것을
못 읽은 것처럼 그리면 사용자가 고장을 찾는다.

카드 높이가 계정마다 달라진다. 이미 Enterprise 카드(예산 한 줄)가 그렇다.

### 4-2. 막대

`BarText.codes` 가 `Codex` 를 `Co` 로 줄인다. 규칙 그대로다. Claude 계정 이름이
`Co` 로 시작해 겹치면 알파벳순 순번이 붙는다. 그것도 규칙 그대로다.

숫자 두 줄은 `.session`, `.weeklyAll` 순이라 `plus` 는 두 줄, `prolite` 는
5시간 자리가 `?` 다. 여기도 카드처럼 **있는 줄만** 올린다. `prolite` 는 주간
한 줄과 게이지 한 줄이다. Enterprise 가 예산 한 줄만 올리는 것과 같은 길이다.

```
T40  91%  ::::::::::::::::::    Co   9%  ::::
     84%  ::::::::::::::
          ::::::::::::::::::
```

막대에 올릴지는 `BarContent` 가 정한다. `chosen` (기본) 은 설정 목록에서 켜
둔 것 전부라 Codex 도 처음부터 올라온다. `windowed` 는 Claude 창을 보는
기준이라 **Codex 는 안 올라간다.** Codex 앱이 떠 있는지로 판정할 수도 있지만
그 앱은 계정별 창이 아니라 그냥 앱이라 "창이 열린 계정" 이라는 말이 안 맞는다.

### 4-3. 설정

계정 목록에 `Codex` 줄이 같이 선다. 체크로 숨기고 화살표로 순서를 정한다.
`uuid` 가 `account_id` 라 `hidden` 과 `order` 가 그대로 걸린다. 따로 만들 것이
없다.

Codex 를 읽을지 여부의 토글은 두지 않는다. `auth.json` 이 있으면 읽고 없으면
안 읽는다. 보이기 싫으면 목록에서 끈다. 설정을 하나 더 두면 "Codex 가 왜
안 뜨지" 를 두 곳에서 찾게 된다.

### 4-4. 차례

순서를 안 정했을 때의 기본 차례.

```
활성 Claude 계정 -> 나머지 Claude 이름순 -> Codex
```

Claude 가 먼저인 것은 이 앱이 Claude 메뉴바 앱으로 시작했고 기존 사용자의
화면이 바뀌면 안 되기 때문이다. 순서를 정했으면 그쪽이 이긴다. 기존 규칙이다.

### 4-5. 알림

`UsageAlerts.build(for:others:)` 가 그대로 돈다. `Codex 5시간 한도 소진`,
`Codex 주간 한도 12% 남음`, 리셋 풀림 알림까지 같다.

`others` 는 **같은 공급자만** 넘긴다. "T52 로 옮기세요" 는 Claude 세션을
옮기는 말이라 Codex 가 막혔을 때 나오면 틀린 말이다. 반대로 Claude 가 막혔을
때 Codex 를 권하는 것도 마찬가지다.

### 4-6. 손대지 않는 자리

작업 이전, 양쪽에 두기, 자동 재개, 인스턴스 띄우기는 Claude 세션 형식과 Claude
앱 인스턴스 위에 있다. 그 화면들이 `model.known` 을 훑는 자리는 `provider ==
.claude` 로 거른다.

| 자리 | 무엇을 거르나 |
|---|---|
| `UsageModel.slot`, `launch`, `focus`, `windowedUUIDs` | Codex 는 `.none` 도 아닌 별도 갈래. 4-1 의 단추 |
| `HandoffModel` 의 대상 계정 목록 | Codex 제외 |
| `ResumeTab` 의 계정 선택 | Codex 제외 |
| `sharedStores`, `mirrorBackAll` | Codex 제외 |
| `FocusMark.focusedUUID` | Codex 는 후보가 아니다 |

---

## 5. clfctl

`clfctl desktop usage` 에 같이 나온다. 표는 이름으로 갈리고 JSON 은 `provider`
필드가 붙는다.

```
* NAVER_TEAM_40  (지금 앱에서 쓰는 계정)
    5시간        [##########..........] 잔여  51%   29분 뒤 리셋
    ...

  Codex  (prolite)
    주간         [##..................] 잔여  91%   6일 18시간 뒤 리셋
```

```json
{"uuid": "c7bbb1fc-...", "name": "Codex", "provider": "codex", "plan": "prolite",
 "limits": {"weekly_all": {"percent": 9, "resets_at": "...", "severity": ""}}}
```

Claude 앱이 없는 기계에서 `clfctl desktop usage` 가 Codex 만 내는 것도 여기서
확인할 수 있다.

---

## 6. 1차에서 빼는 것

| 뺀 것 | 왜 | 언제 넣나 |
|---|---|---|
| `additional_rate_limits` (모델별 한도) | 5시간과 주간이 둘 다 있어 `LimitKind` 하나에 안 들어간다. 이 계정에서는 전부 0% 라 그릴 것도 없다 | 그 한도가 실제로 차오르는 계정이 나오면. `UsageLimit` 에 이름을 얹고 넷째 줄을 둔다 |
| 둘째 Codex 계정 (`CODEX_HOME` 여럿) | 앱이 갱신하지 않는 토큰은 열흘 안에 죽는다. 읽어도 곧 `토큰 만료` 만 남는다 | 설정에 `codexHomes: [String]` 을 두고 각 디렉토리의 `auth.json` 을 같은 리더로 읽는다. 리더는 디렉토리를 인자로 받게 처음부터 만든다 |
| `credits`, `spend_control` | 이 계정에서 전부 0 이고 없음. 무엇이 오는지 모르고 그리면 거짓말이 된다 | 값이 있는 계정을 관측하면. Enterprise 예산 줄과 같은 자리다 |
| 계정 이름을 이메일로 | 카드 폭과 막대 코드 문제. 2절 | 둘째 계정이 들어와 `Codex` 하나로 구별이 안 될 때 |
| Codex 앱 창 관리 | 앱이 스스로 한다 | 하지 않는다 |
| 토큰 갱신 | Claude 와 같은 자세. 읽기만 한다 | 하지 않는다 |

---

## 7. 테스트로 잠글 것

파일과 네트워크를 뺀 나머지가 순수 함수다.

| 테스트 | 잡는 것 |
|---|---|
| `parseCodexUsage` `plus` 응답 | primary -> `.session`, secondary -> `.weeklyAll`, epoch 초 해석 |
| `parseCodexUsage` `prolite` 응답 | primary(604800초) 가 `.weeklyAll` 로, `.session` 없음, `secondary: null` 무시 |
| 사용률 0 | `resetsAt == nil` |
| 모르는 창 길이 | 86400 기준으로 갈림. 죽지 않음 |
| `BarText.codes(["NAVER_TEAM_40", "Codex"])` | `T40`, `Co` |
| `label(for:)` | `.weeklyAll` 이 공급자마다 다름 |
| 스냅샷 합치기 | Claude 리더가 던져도 Codex 가 남음. 둘 다 없으면 실패 |
| 기본 차례 | Claude 활성 -> Claude 이름순 -> Codex |
| 알림 `others` | 공급자가 다른 계정은 안 넘어감 |
| 작업 이전 대상 | Codex 가 목록에 없음 |
