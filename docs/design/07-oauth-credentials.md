# 07. OAuth 자격증명 캡처와 갱신

`claude auth login` 이 만든 전체 스코프 자격증명을 조직마다 확보하고, 만료 전에
스스로 갱신하는 경로. [05 문서](05-account-registration.md)의 `setup-token` 경로를
대체하는 **기본 경로**다.

---

## 1. 왜 이 경로가 필요한가

Claude Code 기본 화면이 보여주는 세 줄 중 마지막이 문제다.

```
5-hour limit          Resets in 3 hr 7 min    9%
Weekly, all models    Resets Fri 6:00 AM      6%
Weekly, Fable                                 0%      <- 여기
```

모델별 주간 한도는 **응답 헤더에 없다.** 헤더는 `anthropic-ratelimit-unified-5h-utilization` 과
`-7d` 뿐이고, 모델별 창은 Usage API 응답의 `limits[]`(`kind == "weekly_scoped"`)가
유일한 출처다. 그리고 그 API 는 `user:profile` 스코프를 요구한다.

`setup-token` 은 `scope=user:inference` 만 준다([05](05-account-registration.md) 2절
실측). 그래서 그 경로로는 세 번째 줄을 영영 볼 수 없다.

**모델별 한도가 clfl 의 핵심 차별점인데 그걸 보지 못하는 것은 모순이다.** 429 를 맞고
나서야 아는 것과 미리 보고 옮기는 것은 다른 도구다.

---

## 2. 두 자격증명

| | `setup-token` | **`auth login` 캡처** |
|---|---|---|
| 스코프 | `user:inference` | inference + **profile** + sessions + mcp + file_upload |
| 갱신 토큰 | 없음 | `sk-ant-ort01-` 있음 |
| 수명 | 1년 | 짧다. `expiresAt` 밀리초 |
| 갱신 책임 | 없음 | **우리** |
| 모델별 주간 한도 | 안 보임 | 보임 |
| 신원 (조직 이름) | 모름 | 캡처 시점에 알 수 있음 |
| 얻는 방법 | stdout 파싱 또는 붙여넣기 | keychain 슬롯 읽기 |

**기본은 `auth login` 캡처다.** `setup-token` 은 캡처가 막히는 환경(CI, 원격 접속)을
위해 남긴다.

1년 수명이 더 단순해 보이지만 아니다. 그것은 **1년 뒤 모든 조직이 같은 주에 한꺼번에
죽는 절벽**이고, 갱신은 앱이 도는 동안 조용히 이어지는 곡선이다. 곡선 쪽이 "그냥 잘
동작" 에 가깝다.

---

## 3. 캡처 흐름

`claude auth login` 은 결과를 **공유 슬롯 하나**에 쓴다. 조직을 바꿔가며 로그인하고
매번 그 슬롯을 읽어 우리 쪽으로 복사한다.

```
[조직 추가]
   |
   v
1  claude auth login 실행
   |    브라우저가 열리고 사용자가 조직을 고른다
   |    (05 문서 2절의 조직 선택 화면)
   v
2  claude auth status 로 방금 무엇이 들어왔는지 확인
   |    email, orgName, subscriptionType 을 얻는다
   |    -> 이름 자동 채우기의 근거
   v
3  keychain 슬롯 "Claude Code-credentials" 를 읽는다
   |    {"claudeAiOauth": {accessToken, refreshToken, expiresAt, scopes, ...}}
   |    지문(accessToken 마지막 8자)으로 중복 확인
   v
4  Usage API 를 한 번 호출해 검증 + 첫 스냅샷
   |    200 이면 모델별 주간까지 채워진다
   v
5  우리 keychain 항목에 자격증명 JSON 전체를 저장
       Claude 의 슬롯은 건드리지 않는다
```

### 우리는 읽기만 한다

CCSwitcher 는 이 슬롯을 **덮어써서** 전환한다([06](06-ccswitcher-comparison.md) 2절).
clfl 은 캡처 시점에 **한 번 읽을 뿐 절대 쓰지 않는다.** 라우팅은 프록시가 헤더로
하므로 남의 자격증명 자리를 바꿀 이유가 없다.

그 결과 세 조직을 캡처하고 나면 Claude 의 슬롯에는 **마지막에 로그인한 조직**이 남는다.
프록시를 거치는 요청은 우리가 헤더를 덮으므로 영향이 없고, 프록시를 우회하는
`claude` CLI 직접 호출만 그 마지막 조직으로 간다. 이 사실을 등록 화면에 한 줄로
알려준다.

### keychain 접근은 `security` CLI 로

Security framework 로 남의 keychain 항목을 읽으면 ACL 이 우리 것이 아니라 매번
프롬프트가 뜬다. 개발 빌드는 코드서명이 바뀔 때마다 자기 항목조차 다시 묻는다.
`security` CLI 는 "항상 허용" 이 유지된다. CCSwitcher 가 같은 이유로 같은 선택을 했다.

```
security find-generic-password -s "Claude Code-credentials" -a "<OS username>" -w
```

우리 자신의 항목도 같은 방식으로 다룬다. 두 경로가 갈리면 프롬프트 동작이 달라져
디버깅이 어려워진다.

### 이름 자동 채우기

2단계에서 `orgName` 을 얻으므로 마법사가 이름을 미리 채울 수 있다.

```
NAVER_TEAM_40  ->  team40   (코드 T1)
NAVER_TEAM_52  ->  team52   (코드 T2)
Naver          ->  naver    (코드 NA)
```

규칙은 소문자화, 영숫자 외 제거, 흔한 접두사(조직 공통 부분) 축약. 사용자가 고칠 수
있게 열어두되 **기본값이 맞아떨어지면 아무것도 안 해도 된다.**

[05 문서](05-account-registration.md) 4절이 "토큰 먼저, 이름 나중" 인 이유가 여기서
완성된다. 캡처가 끝나야 조직 이름을 알 수 있다.

---

## 4. 갱신

### 요청

```
POST https://console.anthropic.com/v1/oauth/token
Content-Type: application/json

{ "grant_type": "refresh_token",
  "refresh_token": "sk-ant-ort01-...",
  "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e" }
```

`client_id` 는 Claude Code 의 공개 PKCE 클라이언트다. `setup-token` 의 authorize URL 에
있던 값과 같다([05](05-account-registration.md) 2절). 비밀이 아니다.

응답에서 `access_token` 과 `expires_in`(초)을 읽는다. `refresh_token` 이 함께 오면
회전된 것이므로 저장된 값을 교체한다.

### 결과를 세 갈래로 나눈다

이 구분이 UX 를 가른다. 네트워크 한 번 끊겼다고 재로그인을 요구하면 안 된다.

```swift
enum RefreshOutcome: Sendable {
    case renewed(accessToken: String, expiresAt: Date)
    /// 이 grant 는 다시는 동작하지 않는다. 재등록만이 답이다.
    case rejected
    /// 토큰의 유효성에 대해 아무것도 말하지 않는다. 다음에 다시 해본다.
    case transient
}
```

판정 규칙:

| 응답 | 판정 | 근거 |
|---|---|---|
| 200 + 파싱 성공 | `renewed` | |
| 4xx + `error == "invalid_grant"` | **`rejected`** | RFC 6749 5.2. 만료/철회/무효를 모두 덮는다 |
| 그 밖의 4xx, 5xx, 429, 타임아웃 | `transient` | 토큰에 대해 말하는 바가 없다 |
| **200 인데 우리 파싱 실패** | `transient` | 스키마 변경이지 죽은 grant 가 아니다 |

마지막 줄이 중요하다. 200 을 파싱 실패로 `rejected` 처리하면 서버가 필드 하나를 바꾼
날 **모든 조직이 한꺼번에 재로그인을 요구한다.**

### 응답 본문을 절대 로그에 남기지 않는다

성공 응답의 첫 바이트가 살아있는 접근 토큰이다. 진단 로그는 회전되어도 남고 문제 신고에
첨부된다.

```swift
// 남겨도 되는 것: 상태 코드, 바이트 수, 허용 목록에 있는 OAuth 에러 코드
let known = ["invalid_grant", "invalid_request", "invalid_client",
             "unauthorized_client", "unsupported_grant_type", "invalid_scope"]
let code = oauthError.map { known.contains($0) ? $0 : "unrecognized" } ?? "none"
log.warning("refresh not applied (HTTP \(status), error=\(code), \(data.count) bytes)")
```

### `scopes` 는 갱신 응답으로 덮어쓰지 않는다

저장된 `scopes` 배열은 그대로 둔다. 우리는 이 값으로 "이 자격증명이 Usage API 를
쓸 수 있는가" 를 판단하는데, 갱신 응답이 더 좁은 스코프 문자열을 실어 보내면 멀쩡한
자격증명의 능력을 스스로 낮추게 된다.

### 언제 갱신하나

```swift
actor TokenProvider {
    /// 요청 직전에 부른다. 만료가 5분 안이면 먼저 갱신한다.
    func accessToken(for id: AccountID) async throws -> String
}
```

- **여유 5분.** 요청이 오래 걸려도 도중에 만료되지 않게
- **계정당 단일 비행.** 동시 요청이 같은 조직의 갱신을 중복 실행하지 않게 한다.
  뒤늦게 온 호출자는 진행 중인 갱신을 기다렸다가 같은 결과를 받는다
- 앱이 오래 떠 있으면 타이머 없이도 요청이 흐를 때마다 자연히 갱신된다.
  **오래 안 쓴 조직은 만료된 채 있다가 다음 사용 직전에 갱신된다.** 그것으로 충분하다

---

## 5. 401 처리가 바뀐다

지금까지 401 은 곧 "이 조직은 죽었다" 였다. 갱신 토큰이 생기면 아니다.

```
401 수신
  |
  +-- 자격증명이 longLived (setup-token)
  |     -> 기존대로 invalid. 재등록 안내
  |
  +-- 자격증명이 oauth
        |
        +-- 이 요청에서 이 조직에 대해 이미 갱신을 시도했나?
        |     yes -> invalid 로 두지 말고 다음 조직으로. 무한 루프 방지
        |
        +-- 강제 갱신 1회
              |
              +-- renewed   -> **같은 조직으로 재시도.** tried 에 넣지 않는다
              +-- rejected  -> invalid 처리 + 다음 조직
              +-- transient -> **invalid 로 표시하지 않고** 다음 조직
```

세 가지가 달라진다.

1. **만료된 토큰이 조직을 태우지 않는다.** 갱신하고 같은 조직으로 계속 간다.
   사용자는 아무것도 눈치채지 못한다. 이것이 "smooth" 의 상당 부분이다
2. **네트워크 문제로 조직을 무효화하지 않는다.** `transient` 는 이번 요청만 건너뛴다
3. 무한 루프 가드가 필요하다. 요청 하나에서 조직 하나당 갱신은 한 번뿐

[03 문서](03-request-flow.md)의 실패 모드 표와 스왑 루프가 이에 맞춰 바뀐다.

---

## 6. Usage API 를 언제 부르나

[01 문서](01-architecture.md) 0절의 원칙은 **폴링하지 않는 것**이다. 모델별 한도를
얻자고 타이머를 다는 순간 그 호출 자체가 한도를 먹고, 유휴 시 CPU 목표도 깨진다.

그래서 **수요가 있을 때만** 부른다.

| 계기 | 대상 | 비고 |
|---|---|---|
| 캡처 직후 | 그 조직 | 등록 검증을 겸한다 |
| 토큰 갱신 직후 | 그 조직 | 어차피 네트워크를 쓰는 김에 |
| 팝오버 열림 | 활성 조직 | 스냅샷이 5분보다 오래됐을 때만 |
| 대화 시작 선제 판단 | 활성 조직 | 스냅샷이 오래됐을 때만 |
| 선제 전환 후보 검증 | **최상위 후보 1건만** | 옮기기 전에 정말 여유 있는지 확인 |

가드:

- **조직당 최소 간격 5분.** 그 안에는 캐시된 스냅샷을 쓴다
- **동시 1건.** 여러 계기가 겹쳐도 하나만 나간다
- **실패는 라우팅을 막지 않는다.** 스냅샷이 없으면 헤더에서 온 값으로, 그것도 없으면
  tier 1 로 내려갈 뿐이다
- **429 면 `Retry-After` 만큼 그 조직 조회를 쉰다.** 사용량을 물어보다 사용량을
  소진하는 것은 앞뒤가 맞지 않는다

마지막 계기가 CCSwitcher 에서 배운 것이다. 묵은 샘플만 보고 옮겼다가 이미 소진된
곳에 착지한 사례가 있었다([06](06-ccswitcher-comparison.md) 5절). 옮기기 직전에
한 번은 확인한다.

### 헤더와 API 를 어떻게 합치나

응답 헤더는 요청이 흐를 때마다 공짜로 온다. Usage API 는 위 계기에만 온다.

```
헤더 도착   -> fiveHour, sevenDayAll 만 갱신. modelWeekly 는 건드리지 않는다
API 도착    -> 세 가지 모두 갱신. source = .usageAPI
```

헤더가 더 자주 오므로 5시간과 전체 주간은 거의 항상 신선하고, 모델별 주간만 조금
묵는다. 모델별 주간은 7일 창이라 분 단위 신선도가 필요없으므로 균형이 맞다.

---

## 7. 실패 모드

| 상황 | 대응 | 사용자에게 |
|---|---|---|
| keychain 슬롯이 비어 있음 (`auth login` 미완료) | 캡처 중단. 다시 시도 안내 | 마법사에 그대로 표시 |
| 슬롯은 있는데 지문이 기존 조직과 같음 | 저장하지 않는다. 다른 조직을 고르라고 안내 | 중복 경고 |
| `scopes` 에 `user:profile` 없음 | 저장은 하되 모델별 주간을 비활성 | "이 조직은 모델별 한도를 볼 수 없습니다" |
| 갱신 `rejected` | 조직 `invalid`. 재등록 버튼 | 계정 카드 `!` |
| 갱신 `transient` 반복 | 무효화하지 않는다. 점검 화면에만 표시 | 조용히 |
| Usage API 403 | 모델별 주간만 포기. 라우팅은 정상 | 조용히. 점검에 기록 |
| Usage API 429 | `Retry-After` 만큼 그 조직 조회 중단 | 없음 |
| 갱신 응답 스키마 변경 | `transient` 로 처리해 전 조직 동시 무효화를 막는다 | 점검 화면 경고 |

마지막 줄이 이 설계에서 가장 조심한 지점이다. **한 번의 서버 변경으로 모든 조직이
동시에 죽는 경로를 만들지 않는다.**

---

## 8. 저장 형태

```swift
enum CredentialKind: String, Codable, Sendable {
    case longLived      // setup-token. 문자열 하나
    case oauth          // auth login 캡처. JSON 블록 전체
}
```

`Account` 에 `credentialKind` 를 둔다. Keychain 에는 종류에 따라 다른 것이 들어간다.

| 종류 | Keychain 값 |
|---|---|
| `longLived` | `sk-ant-oat01-...` 문자열 |
| `oauth` | `{"claudeAiOauth": {accessToken, refreshToken, expiresAt, scopes, ...}}` |

두 경우 모두 **프록시가 업스트림에 붙이는 것은 접근 토큰 하나**다. `rewriteAuth` 는
`sk-ant-oat01-` 접두사를 보고 `Authorization: Bearer` + `anthropic-beta` 를 붙이므로
([포팅 01](../porting/01-headers-and-auth.md) 2절) 종류에 따라 갈리지 않는다.

갈리는 것은 그 접근 토큰을 얻는 방법뿐이다. `longLived` 는 저장값 그대로,
`oauth` 는 `TokenProvider` 를 거쳐 필요하면 갱신한 뒤.

---

## 9. 다른 문서에 미치는 영향

| 문서 | 변경 |
|---|---|
| [01 아키텍처](01-architecture.md) | `ClflStore` 가 Claude 의 keychain 슬롯을 **읽는다**(쓰지 않는다). `TokenProvider` 가 `ClflProxy` 에 추가 |
| [02 도메인 모델](02-domain-model.md) | `Account.credentialKind`. `RateLimitSnapshot.source` 가 실제로 두 값을 갖게 됨 |
| [03 요청 흐름](03-request-flow.md) | 401 분기가 갱신 시도를 포함. 실패 모드 표에 갱신 항목 |
| [05 계정 등록](05-account-registration.md) | `setup-token` 경로가 기본에서 **폴백**으로. 마법사가 두 경로를 제시 |
| [04 구현 설계](04-implementation.md) | 구현 순서에 캡처와 갱신이 추가 |

---

## 10. 아직 확인하지 못한 것

- `claude auth login` 이 파이프로도 동작하는지. `setup-token` 은 확인했지만
  ([05](05-account-registration.md) 2절) `auth login` 은 별도다. 안 되면 사용자가
  터미널에서 직접 실행하고 앱은 슬롯을 읽기만 하는 형태로 떨어진다
- 슬롯의 계정 이름이 정말 OS 사용자명인지. 다른 값이면 슬롯을 찾지 못한다
- `expires_in` 이 실제로 몇 초인지. 갱신 주기와 여유 5분의 적정성이 여기 달렸다
- Usage API `limits[]` 의 정확한 스키마. claulay 의 `oauth-usage.ts` 가 파싱하는
  모양을 기준으로 삼되 실제 응답으로 확인해야 한다

넷 다 캡처를 한 번 돌려보면 드러난다. 구현 순서에서 이 단계를 앞으로 당길 이유다.
