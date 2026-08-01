# 06. CCSwitcher 비교 분석

`/Users/cpm4/repos/CCSwitcher` (v1.12.0, build 66) 를 읽고 clfl 설계와 대조한 것.
같은 문제를 **정반대 방식**으로 푼 앱이라 배울 것과 다시 생각할 것이 둘 다 있다.

---

## 1. 무엇을 만들었나

성숙한 오픈소스 macOS 메뉴바 앱이다.

| 항목 | 값 |
|---|---|
| 스택 | Swift 6, macOS 14+, XcodeGen(`project.yml`) |
| 구성 | 앱 타겟 + 위젯 확장(ExtensionKit) + Shared |
| 배포 | Sparkle 2.x 자동 업데이트, Homebrew tap, GitHub Actions |
| 국제화 | 영어, 중국어, 일본어, 독일어, 프랑스어 |
| 코드 | Services 13, Models 11, Views 11 |
| 샌드박스 | 앱은 off, 위젯만 on + app group |
| 대상 | Claude Code, Codex, Gemini (provider 개념 있음) |

clfl 이 아직 문서만 있는 단계인 것과 대비된다. 배포 파이프라인, 위젯, 다국어까지
갖춘 실제 제품이다.

---

## 2. 근본 차이: 전환 메커니즘

**이것 하나가 나머지 모든 차이를 만든다.**

### CCSwitcher: 자격증명 스왑

프록시가 없다. 네트워크에 전혀 개입하지 않는다. 대신 **Claude CLI 가 읽는 자리를
직접 덮어쓴다.**

```
macOS Keychain
  "Claude Code-credentials" / <OS username>     <- Claude CLI 가 소유. 여기를 덮어쓴다
  "com.ccswitcher.tokens"   / <계정 UUID>       <- CCSwitcher 가 계정별로 백업

~/.claude.json 의 oauthAccount 블록              <- 신원 정보. 토큰과 짝을 맞춰 함께 교체
```

전환은 이 두 짝을 원자적으로 바꾸는 것이다. 그 뒤 `claude` 가 호출하면 새 계정으로 간다.

Security framework 가 아니라 **`security` CLI** 를 쓴다. 프레임워크로 접근하면
Claude 의 keychain 항목은 ACL 이 남의 것이라 매번 프롬프트가 뜨고, 자기 항목조차
개발 빌드마다 코드서명이 바뀌어 다시 묻는다. CLI 는 "항상 허용" 이 유지된다.

### clfl: HTTP 프록시

`settings.json` 의 `env.ANTHROPIC_BASE_URL` 로 트래픽을 우리 포트로 돌리고, 요청마다
헤더에 토큰을 주입한다. Claude 의 keychain 도 `~/.claude.json` 도 건드리지 않는다.

### 파생되는 차이

| | CCSwitcher | clfl |
|---|---|---|
| 네트워크 개입 | 없음 | 로컬 홉 하나 |
| 남의 파일/keychain 수정 | **한다** (Claude 의 자격증명 자리) | 안 한다 (settings.json 의 env 한 줄만) |
| 진행 중인 요청 | **못 구한다** | 같은 턴 안에서 구한다 |
| 전환 반영 시점 | 다음 API 호출부터 | 즉시 |
| MCP tool search | **정상** | 제약 (`ENABLE_TOOL_SEARCH` 로 복구) |
| Remote Control | **정상** | 사용 불가 |
| 앱이 꺼져 있을 때 | 마지막 계정으로 그냥 동작 | settings.json 을 지우고 나가야 함 |

**마지막 세 줄이 아프다.** clfl 이 README 에 "알려진 대가" 로 적은 제약이
CCSwitcher 에는 아예 없다. 프록시를 안 쓰기 때문이다.

---

## 3. 왜 우리 계정을 추가할 수 없었나

실사용에서 회사 멀티계정을 추가하지 못했다. 원인이 코드에 있다.

```swift
// AppState.swift:226, addAccount()
guard let email = status.email else { ... }

if accounts.contains(where: { $0.email == email }) {
    errorMessage = "Account already exists"
    return                      // 거부
}
```

**CCSwitcher 의 계정 식별 축은 이메일이다.** `claude auth status` 가 돌려주는 email 로
중복을 판정한다.

그런데 [05 문서](05-account-registration.md) 2절에서 실측한 우리 환경은 **한 SSO
로그인 아래 조직이 여럿**이다.

```
로그인: sw.chae@navercorp.com   (하나)
  +-- Naver
  +-- NAVER_TEAM_52
  +-- NAVER_TEAM_40
```

세 조직의 이메일이 전부 같다. 그래서:

- 첫 조직 등록 -> 성공
- 둘째 조직 등록 -> `claude auth status` 가 **같은 이메일**을 반환 -> "Account already exists" 로 거부

`loginNewAccount` 경로는 더 나쁘다. 거부가 아니라 **기존 항목의 백업을 새 토큰으로
덮어쓰고 활성으로 표시**한다(`AppState.swift:324`). 조직 A 의 백업 자리에 조직 B 의
토큰이 들어간다. 자기네 지문 진단이 잡으려던 그 오염이다.

`Account` 에 `orgName` 필드가 있고 표시에도 쓰지만(`displayName: status.orgName ?? email`),
**중복 판정은 이메일로만 한다.** 조직이 식별 축이 아니라 장식이다.

### 이것이 clfl 의 존재 이유를 바꾼다

앞 절에서 프록시 비용을 정당화하는 근거로 모델별 한도와 진행 중 요청 구제를 꼽았다.
여기에 더 앞서는 것이 하나 있다.

**clfl 은 애초에 신원으로 계정을 구분하지 않는다.** 사용자가 이름을 붙이고 우리는
토큰을 그 이름에 묶을 뿐이다. [05 문서](05-account-registration.md) 6절에서 "토큰이
어느 조직 것인지 알 수 없다" 를 한계로 적었는데, **한 이메일에 조직이 여럿인 환경에서는
오히려 그게 맞는 모델이다.** 신원으로 묶으려 들면 세 조직이 한 계정으로 붕괴한다.

CCSwitcher 가 이걸 고치려면 식별 축을 `(email, orgId)` 로 바꿔야 한다. 가능한 수정이고
아마 언젠가 할 것이다. 다만 지금은 안 되고, 우리에게는 지금 필요하다.

---

## 4. 토큰이 다르다 - 가장 중요한 발견

두 앱이 쓰는 토큰의 **종류가 다르다.** 이건 clfl 설계를 다시 보게 만든다.

| | CCSwitcher | clfl (현재 설계) |
|---|---|---|
| 획득 | `claude auth login` | `claude setup-token` |
| 접근 토큰 | `sk-ant-oat01-` | `sk-ant-oat01-` (같음) |
| **갱신 토큰** | **`sk-ant-ort01-` 있음** | 없음 |
| **스코프** | inference + **profile** + sessions + mcp + file_upload | **inference 만** |
| 수명 | 짧다 (`expiresAt` 밀리초). 갱신 필요 | 1년 |
| 신원 조회 | **가능** (`claude auth status` -> email/org) | 불가 |
| Usage API | **가능** | 403 |

CCSwitcher 가 관측한 실제 토큰 JSON:

```json
{ "claudeAiOauth": {
    "accessToken":  "sk-ant-oat01-...",
    "refreshToken": "sk-ant-ort01-...",
    "expiresAt": 1774128766541,
    "scopes": ["user:file_upload","user:inference","user:mcp_servers",
               "user:profile","user:sessions:claude_code"],
    "subscriptionType": "pro", "rateLimitTier": "default_claude_ai" } }
```

**`user:profile` 이 들어 있다.** [05 문서](05-account-registration.md) 에서 우리가
"토큰이 어느 조직 것인지 알 수 없다" 고 결론낸 것은 `setup-token` 의
`scope=user:inference` 전제였다. `auth login` 토큰을 쓰면 그 한계가 사라진다.

같은 client_id 다. setup-token 의 authorize URL 에 있던
`9d1c250a-e61b-44d9-88ed-5944d1962f5e` 가 CCSwitcher 의 `oauthClientID` 상수와 같다.
공개 PKCE 클라이언트라 CCSwitcher 는 `https://console.anthropic.com/v1/oauth/token`
으로 **직접 갱신**한다. CLI 를 거치지 않는다.

### Usage API

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
```

`anthropic-beta` 플래그가 clfl 이 [포팅 01](../porting/01-headers-and-auth.md) 에서
다루는 것과 같은 값이다. 403 은 "활성 Pro/Max 구독 없음" 을 뜻한다.

---

## 5. 전환 전략

### CCSwitcher: 선제적, 폴링 기반, threshold + hysteresis

`AutoSwitchEngine.swift` 113줄이 순수 결정 로직이고 상태가 필요한 가드는 전부
`AppState` 에 있다. **우리가 ClflCore 를 순수하게 두려는 것과 같은 분리다.**

```
5분마다 refresh
  |
  +-- 라운드로빈 폴링: 활성 계정(항상) + 비활성 1개만
  |     API 부하와 사용량 소모를 억제한다
  |
  +-- binding utilization = max(5시간, 7일) 사용률
  |
  +-- 활성이 threshold(기본 90%) 도달?
  |     아니면 아무것도 안 함
  |
  +-- 후보 = threshold - hysteresis(10%) 이하인 계정만
  |     즉 80% 이하. 경계에서 핑퐁하지 않게
  |
  +-- 여유 많은 순 정렬
  |
  +-- 1순위 후보를 fresh 하게 재검증 (요청 예산 1회)
  |     실패하면 다음 후보로. 이번 사이클에 이미 샘플한 것만
  |
  +-- 검증 중 상태가 바뀌었으면 stand down
  |
  +-- 전환. 쿨다운 300초 시작
```

가드레일이 촘촘하다.

| 가드 | 목적 |
|---|---|
| 쿨다운 300초 | 한 창에 한 번만 |
| 재진입 플래그 | `switchTo` 가 `refresh` 를 부르고 그게 다시 평가를 부른다 |
| `isLoggingIn` / `isSwitching` / `isRefreshing` 체크 | 사용자 조작과 겹치지 않게 |
| `resets_at` 만료 샘플 폐기 | 라운드로빈이라 샘플이 몇 사이클 묵을 수 있다 |
| 활성 쪽은 strict, 후보 쪽은 lenient | 만료 미상 샘플이 **전환을 유발**하면 안 된다 |
| **읽기 없는 후보는 부적격** | 아래 참고 |
| 커밋 전 fresh 재검증 | 묵은 샘플로 착지하지 않게 |

`AutoSwitchEngine.swift` 주석에 실제로 겪은 버그가 적혀 있다.

> 계정은 라운드로빈으로 폴링되므로 "샘플 없음" 은 대개 "아직 차례가 아님" 이지
> "한가함" 이 아니다. 이걸 폴백으로 취급했더니 **자동 전환이 이미 소진된 계정에
> 착지했다.** 이 기능이 막으려던 바로 그 실패다.

### clfl: 반응형 + 대화 시작 시 선제 강등

| | CCSwitcher | clfl |
|---|---|---|
| 주 트리거 | 사용률 임계값 | **429 수신** |
| 데이터 취득 | Usage API 능동 폴링 | 응답 헤더 편승 |
| 폴링 비용 | 5분마다 계정 2개 | **0** |
| 판단 시점 | 타이머 | 요청이 흐를 때 |
| 임계값 방식 | threshold + hysteresis | threshold 만 (2단계 정렬) |
| 보는 창 | max(5h, 7d) | **5h 만** |
| 모델별 한도 | 없음 | (계정, 모델) 쿨다운 |
| 같은 턴 구제 | 불가 | 가능 |

---

## 6. clfl 에 반영할 것

읽으면서 우리 설계의 구멍이 다섯 개 드러났다.

### 6-1. hysteresis 가 없다

[02 문서](02-domain-model.md) 3절의 선제 강등은 임계값 하나로 tier 를 가른다.
두 계정이 경계 근처에 있으면 대화마다 왔다 갔다 할 수 있다.

우리는 대화 시작에만 적용하므로 CCSwitcher 만큼 심하지는 않다. 하지만 짧은 대화를
연달아 열면 같은 증상이 난다. **tier 경계에 hysteresis 를 넣어야 한다.**

### 6-2. 7일 창을 보지 않는다

우리 `SelectionInput.proactiveThreshold` 는 5시간 잔여만 본다. **7일이 먼저 바닥나는
경우를 통째로 놓친다.**

아이러니하게도 우리가 [시안](ui-spec.html)에 넣은 전환 직후 예시가 정확히 그
경우다. `T1 53% / 0%` - 5시간은 절반 넘게 남았는데 7일이 0% 라서 넘어온 상황.
선제 전환 로직이 그걸 못 본다.

CCSwitcher 의 `bindingUtilization = max(5h, 7d)` 를 그대로 가져와야 한다.

### 6-3. 오래된 스냅샷을 그대로 믿는다

우리는 폴링을 안 하니 안전하다고 생각했는데 아니다. 어떤 계정을 오래 안 쓰면
`RateLimitSnapshot` 이 며칠 묵는다. 그 사이 창이 리셋됐으면 **실제로는 비어 있는
계정을 소진된 것으로 보고 건너뛴다.**

CCSwitcher 의 규칙을 그대로 쓸 수 있다.

- `resetsAt` 이 지난 샘플은 버린다
- 창이 아직 안 지났으면 사용량은 늘기만 하므로 묵은 값도 유효한 하한이다
- 활성 계정 판단에는 strict, 후보 판단에는 lenient

### 6-4. 쿨다운과 재진입 가드가 없다

우리 설계에 "전환 직후 다시 전환하지 않는다" 는 장치가 없다. 반응형이라 429 가
자연스러운 브레이크 역할을 하지만, 선제 전환을 넣는 순간 필요해진다.

### 6-5. auth login 토큰을 선택지에서 뺐다

[05 문서](05-account-registration.md) 전체가 `setup-token` 전제다. `auth login` 토큰을
쓰면 신원 조회와 Usage API 가 열린다. 다만 대가가 있다.

| | setup-token | auth login |
|---|---|---|
| 얻는 것 | 1년 수명, 갱신 불필요 | 신원 조회, Usage API, 모델별 한도 가시성 |
| 잃는 것 | 신원, Usage API | **짧은 수명. 갱신을 우리가 책임져야 함** |
| 저장 | 우리 Keychain 항목 | 우리 Keychain 항목 (백업으로) |

갱신 책임이 무겁다. CCSwitcher 는 refresh token 으로 직접 갱신하고, 실패를
`rejected`(재인증 필요) 와 `transient`(네트워크) 로 구분하는 로직까지 갖고 있다.

**1차에서는 setup-token 을 유지하되, 등록 화면에 두 경로를 나란히 둘 여지를 남긴다.**
Usage API 가 열리면 선제 전환의 정확도가 크게 올라가므로 언젠가는 필요하다.

---

## 7. 다시 생각할 것: 우리 트레이드오프가 옳은가

CCSwitcher 를 보고 나면 clfl 의 근본 선택을 다시 물어야 한다.

```
clfl        : 같은 턴 스왑을 얻고, MCP tool search 와 Remote Control 을 잃는다
CCSwitcher  : 그 둘을 지키고, 같은 턴 스왑을 포기한다
```

**그리고 선제 전환이 잘 되면 같은 턴 스왑이 필요할 일이 거의 없다.** 미리 넘어가
있으면 429 를 맞지 않는다. CCSwitcher 가 프록시 없이도 실제로 쓸 만한 이유다.

프록시가 여전히 값진 경우는 좁다.

- 폴링 간격 사이에 갑자기 소진 (긴 요청 하나가 남은 여유를 다 먹는 경우)
- 여러 기기에서 같은 계정을 동시에 쓰는 경우
- **모델별 한도** (fable 주간 등). Usage API 의 5h/7d 로는 안 보인다
- 계정 전체가 아니라 특정 모델만 막혔을 때 다른 모델은 계속 쓰기

마지막 두 개가 clfl 의 진짜 차별점이다. CCSwitcher 는 계정 단위로만 전환하므로
`fable` 주간 한도가 소진돼도 `opus` 가 멀쩡한 상황을 표현하지 못한다.
claulay 가 `model-cooldowns.json` 을 도입하며 배운 바로 그 문제다.

### 정직하게 정리하면

| 이런 사용자라면 | 어느 쪽 |
|---|---|
| 조직 2~3개, 하루 몇 시간, MCP 를 많이 씀 | **CCSwitcher.** 이미 있고 성숙하다 |
| 조직 6개, 종일 사용, 모델별 한도에 자주 걸림 | clfl |
| Agent teams 나 백그라운드 세션을 씀 | clfl (프록시가 자식까지 커버) |
| Remote Control 이 필요 | CCSwitcher |

**clfl 을 계속 만들 이유는 있다.** 다만 "다중 계정 전환기" 가 아니라
**"모델별 한도까지 보는, 같은 턴 안에서 끊김 없는 라우터"** 로 좁혀 말해야 정직하다.
그게 프록시 비용을 지불할 유일한 근거다.

---

## 8. 구조에서 배울 것

메커니즘과 별개로 구현에서 가져올 것들.

| 항목 | 배울 점 |
|---|---|
| `AutoSwitchEngine` 분리 | 순수 결정 로직 113줄, 상태 가드는 AppState. 우리 ClflCore 원칙과 같다 |
| `security` CLI | 개발 빌드마다 코드서명이 바뀌어 Security framework 는 프롬프트가 반복된다 |
| XcodeGen `project.yml` | 앱+위젯 타겟을 선언적으로. `.xcodeproj` 충돌이 사라진다 |
| Sparkle + EdDSA 서명 | 사내 배포에도 그대로 쓸 수 있는 자동 업데이트 |
| LSUIElement 설정창 우회 | 메뉴바 전용 앱에서 SwiftUI `Settings` 씬이 안 열리는 문제. 실제 해법이 문서화되어 있다 |
| 위젯 + app group | 메뉴바 밖으로 상태를 내보내는 경로 |
| 지문 기반 진단 | 백업 토큰들의 마지막 8자를 비교해 중복/desync 를 상시 감지. 우리 `tokenFingerprint` 와 같은 발상 |
| `~/.claude.json` 짝 맞춤 | 토큰만 바꾸면 신원이 어긋난다. 남의 상태를 건드릴 때의 대가 |

`AutoSwitchEngine.swift` 의 주석은 그대로 읽을 가치가 있다. 왜 이 가드가 있는지가
전부 실패 경험으로 적혀 있다. claulay 의 `swap.ts` 주석과 같은 성격의 자산이다.

---

## 9. 반영 결과

06 을 쓴 뒤 실사용 확인(3절)과 함께 아래를 반영했다.

| 항목 | 반영 |
|---|---|
| 6-1 hysteresis | [02](02-domain-model.md) 3절. tier 0 진입선을 `threshold + hysteresis` 로. 기본 15% + 10% |
| 6-2 7일 창 | [02](02-domain-model.md) 3절 `bindingHeadroom`. 두 창 중 **더 빡빡한 쪽** |
| 6-3 샘플 만료 | 같은 함수. `resetsAt` 지난 창은 폐기. 활성은 strict, 후보는 lenient |
| 6-4 쿨다운/재진입 | [02](02-domain-model.md) 3-4절. **반응형에는 걸지 않는다** |
| 6-5 auth login 토큰 | 1차 범위 밖. 4절에 선택지로 기록 |
| 7절 포지셔닝 | README 를 "한도 관리" 로 좁힘. 비용 추적은 범위에서 뺌 |

### 우리가 CCSwitcher 와 다르게 간 지점

**읽기 없는 후보를 제외하지 않고 tier 1 로 내린다.** 그쪽은 부적격 처리하는데, 선제
전환만 하므로 후보를 빼도 제자리에 있으면 그만이기 때문이다. clfl 은 반응형 경로가
함께 있어 후보를 풀에서 빼면 429 때 넘어갈 곳이 사라진다.

**반응형 스왑에는 쿨다운을 걸지 않는다.** 429 는 판단이 아니라 서버의 사실 통보다.
쿨다운으로 막으면 요청이 그냥 실패한다.

---

## 10. 남은 것

- 선제 전환 임계값의 실제 값. `usage.jsonl` 과 `audit.jsonl` 을 조인해 전환이 유발한
  캐시 재생성량을 재고 나서 정한다
- `auth login` 토큰 경로. Usage API 가 열리면 선제 전환 정확도가 오르지만 갱신 책임이
  따라온다
- CCSwitcher 의 `AutoSwitchEngine.swift` 주석은 계속 참고할 가치가 있다. 왜 그 가드가
  있는지가 전부 실패 경험으로 적혀 있다

---

## 실측 후기: CCSwitcher 는 어떻게 전환하나

앞의 대조는 코드를 훑어 쓴 것이고, 8단계에서 데스크톱 앱의 실제 동작을 확인한
뒤 다시 읽었다. 두 가지가 확정됐다.

### 자격증명 자리를 통째로 덮어쓴다

`ClaudeService.switchAccount` 가 하는 일은 네 단계다.

```
1. 현재 계정 백업 (토큰 + oauthAccount 를 자기 Keychain 항목에)
2. 대상 계정 백업을 꺼낸다
3. Keychain "Claude Code-credentials" 슬롯에 대상 토큰을 쓴다
   ~/.claude.json 의 oauthAccount 블록도 대상 것으로 쓴다
4. claude auth status 로 검증. 이메일이 대상과 다르면 실패 처리
```

프록시가 없다. **저장소를 바꾸고 CLI 가 다음에 읽게 한다.**

### 대상은 터미널 CLI 뿐이다

`ARCHITECTURE.md` 에 `desktop`, `Claude.app`, `electron` 언급이 하나도 없다.
`AGENTS.md` 는 `ClaudeService` 를 "Wraps `claude` CLI (auth/status)" 라고 적는다.
검증 단계가 `claude auth status` 인 것도 같은 말이다.

이는 우리가 8단계에서 확인한 사실과 맞물린다. `Claude Code-credentials` 슬롯과
`~/.claude.json` 은 **터미널 `claude` 가 읽는 자리**다. 데스크톱 앱은 그 자리를
읽지 않는다. 앱은 claude.ai 세션 쿠키로 인증하고 조직은 암호화된 `lastActiveOrg`
쿠키로 정한다. [08 검증](08-verification.md) 7-4절.

**즉 CCSwitcher 방식으로는 데스크톱 앱을 전환할 수 없다.** 우리가 못 하는 것이
아니라 그 접근 자체가 CLI 전용이다.

### 왜 이 저장소 사용자의 조직을 못 넣었나

`AppState.swift:226` 이 계정을 이메일로 중복 제거한다.

```swift
if accounts.contains(where: { $0.email == email }) {
```

이 저장소 사용자의 세 조직은 전부 같은 이메일 아래에 있다. 조직 목록 API 로
확인했다.

| 조직 | 플랜 |
|---|---|
| NAVER_TEAM_40 | Team |
| NAVER_TEAM_52 | Team |
| Naver | Enterprise |

CCSwitcher 는 이 셋을 계정 하나로 본다. 그래서 둘째부터 추가가 거부된다.

더 근본적으로, 이 셋은 **토큰이 따로 있는 것이 아니라 같은 로그인 안에서 조직만
다르다.** 토큰 슬롯을 갈아끼우는 방식은 애초에 표현할 수 있는 대상이 아니다.

| | CCSwitcher | 이 저장소가 다루는 것 |
|---|---|---|
| 전환 단위 | 계정 (이메일별) | 조직 (한 이메일 아래 여럿) |
| 전환 방법 | 토큰 슬롯 덮어쓰기 | 요청 헤더로 조직별 토큰 라우팅 |
| 대상 | 터미널 CLI | 터미널 CLI |
| 진행 중 요청 | 구제 못 함 | 스왑으로 구제 |

세 번째 줄이 같아진 것이 8단계의 소득이다. 처음에는 데스크톱 앱을 대상으로 적었는데
틀렸다.
