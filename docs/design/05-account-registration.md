# 05. 계정 등록 (setup-token 경로)

토큰을 어떻게 얻고, 검증하고, 저장하는가. claulay 에서 가져오는 경로까지.

> **이 문서는 폴백 경로다.** 기본 경로는 `claude auth login` 자격증명 캡처이고
> [07 문서](07-oauth-credentials.md)에 있다. `setup-token` 은 스코프가 추론 전용이라
> 모델별 주간 한도를 볼 수 없어서, 캡처가 막히는 환경(CI, 원격 접속)을 위해 남긴다.
> 아래 2절의 실측 기록은 두 경로 모두에 유효하다.

---

## 1. 토큰 발급은 우리가 대신할 수 없다

Anthropic 계정 토큰을 얻는 지원되는 경로는 하나뿐이다.

```bash
claude setup-token
```

이 명령이 브라우저를 열어 OAuth 를 태우고 `sk-ant-oat01-...` 로 시작하는 장기 토큰을
출력한다. claulay 도 이 값을 프롬프트로 받아 저장할 뿐, 자체 인증 흐름을 갖고 있지
않다.

**clfl 도 OAuth 를 직접 구현하지 않는다.**

- authorize 엔드포인트, client_id, redirect URI, PKCE 파라미터가 전부 Claude Code
  내부 값이다. 문서화되어 있지 않다
- 남의 OAuth 클라이언트를 흉내 내는 셈이 된다
- 그쪽이 바꾸면 조용히 깨진다

그래서 등록 흐름의 목표는 "우리가 토큰을 만든다" 가 아니라 **"사용자가 토큰을 얻어
넣는 과정을 최대한 짧고 안전하게 만든다"** 이다.

---

## 2. 실제로 관측된 흐름

Claude Code v2.1.220 에서 확인한 것. 추측이 아니라 실측이다.

### 1단계 - 명령 실행

```
$ claude setup-token
Welcome to Claude Code v2.1.220
  (ASCII 배너)

Browser didn't open? Use the url below to sign in (c to copy)

https://claude.com/cai/oauth/authorize?code=true&client_id=...
  &response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback
  &scope=user%3Ainference&code_challenge=...&code_challenge_method=S256&state=...

Paste code here if prompted >
```

- 기본 브라우저를 **직접 연다**
- 동시에 **authorize URL 을 표준 출력에 찍는다** (`c` 로 복사 가능)
- 콜백이 자동으로 안 돌아오는 경우를 대비해 stdin 으로 코드를 받을 준비를 한다.
  정상 경로에서는 입력이 필요없다
- `scope=user:inference`

### 2단계 - 브라우저에서 조직 선택

로그인을 통과하면 **"조직 선택"** 화면이 뜬다.

```
조직 선택
Claude Code와 연결할 조직을 선택하세요

  Naver            >
  NAVER_TEAM_52    >
  NAVER_TEAM_40    >
```

### 3단계 - 토큰 출력

```
O Long-lived authentication token created successfully!

Your OAuth token (valid for 1 year):

sk-ant-oat01-...

Store this token securely. You won't be able to see it again.
Use this token by setting: export CLAUDE_CODE_OAUTH_TOKEN=<token>
```

### 파이프로 붙였을 때

`claude setup-token | cat` 으로 실측했다. 자동 캡처가 가능한지 판별하는 시험이었다.

```
Welcome to Claude Code v2.1.220
Welcome to Claude Code v2.1.220

 . Opening browser to sign in...Welcome to Claude Code v2.1.220

 * Opening browser to sign in...Welcome to Claude Code v2.1.220

   (스피너 프레임마다 전체 화면을 다시 출력. 20회 반복)

 Browser didn't open? Use the url below to sign in (c to copy)

https://claude.com/cai/oauth/authorize?...&state=zR6uvVKmg5rR9USOORdXFXtBbmXxeVPkXzLFjhrXeR
0

 Paste code here if prompted >Welcome to Claude Code v2.1.220

 v Long-lived authentication token created successfully!

 Your OAuth token (valid for 1 year):

 sk-ant-oat01-pgMLy84_Cy1lyuVJz-hnYFf4m54YyHqcw-...

 Store this token securely. You won't be able to see it again.
```

**결론: TTY 없이도 토큰이 나온다. 자동 캡처는 가능하다.** PTY 를 붙일 필요가 없다.

다만 출력이 깨끗하지 않다. 세 가지를 알아냈다.

| 관측 | 의미 |
|---|---|
| 스피너 프레임마다 화면 전체를 다시 출력 | 커서 이동을 못 하니 전체 재출력으로 대신한다. `Welcome to Claude Code` 가 20번 넘게 나온다 |
| **URL 끝이 잘려 다음 줄에 `0` 하나만 남았다** | 긴 줄이 어딘가에서 접힌다. **URL 을 줄 단위로 파싱하면 깨진다** |
| 브라우저는 파이프여도 그대로 열린다 | 우리가 URL 을 가로채 열어줄 필요가 없다 |

세 번째가 두 번째를 무해하게 만든다. [3-2 절](#3-2-브라우저-세션을-격리할-필요가-없다)에서
세션 격리가 불필요하다고 결론냈으므로 **URL 을 파싱할 이유가 애초에 없다.** 명령이
알아서 브라우저를 열게 두고, 우리는 토큰 줄 하나만 본다.

---

### 확정된 사실

| 사실 | 설계에 미치는 영향 |
|---|---|
| authorize URL 이 stdout 에 찍힌다 | 앱이 URL 을 가로채 원하는 곳에서 열 수 있다 |
| 토큰이 stdout 에 찍힌다 | 자동 캡처가 가능하다. 3-1 절 |
| **한 로그인에 조직이 여럿이고 그중 하나를 고른다** | **로그아웃 절차가 필요없다. 3-2 절에서 가정을 뒤집는다** |
| 토큰 유효기간 1년 | 만료 추적이 필요하다. 6절 |
| `scope=user:inference` | Usage API 도 신원 조회도 불가능. 5절의 한계가 확정됐다 |
| 다시 볼 수 없다 | 수동 복사 실패 시 처음부터. 자동 캡처의 근거가 하나 더 |
| `CLAUDE_CODE_OAUTH_TOKEN` 환경변수 존재 | 단일 조직만 쓸 거면 clfl 없이도 된다. 11절 |
| 파이프로도 토큰이 나온다 | PTY 불필요 |
| 출력이 재출력 스팸이고 긴 줄이 접힌다 | 파싱을 방어적으로. 3-1 절 |

---

## 3. 세 가지 개선

### 3-1. 명령을 대신 실행하고 토큰 줄만 집는다

붙여넣기가 **기본 경로**이고, 자동 캡처는 그 위에 얹는 가속기다. 순서를 이렇게 두는
이유는 자동 캡처가 Claude Code 의 TUI 출력 모양에 의존하기 때문이다. 그쪽이 렌더링을
바꾸면 파싱이 깨지는데, 그때 **등록 자체가 불가능해지면 안 된다.**

```
앱이 claude setup-token 실행 (COLUMNS 를 크게 준다)
  -> 명령이 알아서 브라우저를 연다. 우리는 URL 을 건드리지 않는다
  -> 사용자가 브라우저에서 조직을 고른다
  -> 누적 버퍼에서 sk-ant-oat01- 로 시작하는 조각을 찾는다
  -> 찾으면 곧바로 Keychain 으로. 못 찾고 시간이 지나면 붙여넣기 화면으로 전환
```

성공하면 **토큰이 화면에도 클립보드에도 나타나지 않는다.** "다시 볼 수 없습니다" 라는
경고가 무의미해진다. 애초에 사람 손을 거치지 않는다.

#### 파싱을 방어적으로

파이프 출력이 재출력 스팸이고 긴 줄이 접히므로 순진한 줄 단위 매칭으로는 부족하다.

```swift
// 1. 자식 환경을 정리해 노이즈와 줄바꿈을 줄인다
env["COLUMNS"]     = "400"   // Ink 가 줄을 접지 않게. 토큰은 약 108자
env["NO_COLOR"]    = "1"
env["FORCE_COLOR"] = "0"
env["CI"]          = ""      // CI 로 오인해 다른 경로를 타지 않도록 비워둔다

// 2. stdin 은 열어둔 채 아무것도 쓰지 않는다.
//    "Paste code here if prompted >" 에서 EOF 를 만나면 중단될 수 있다
//
// 3. 누적 버퍼 전체에서 찾는다. 줄 단위로 자르지 않는다
let pattern = /sk-ant-oat01-[A-Za-z0-9_\-]{40,}/
```

`COLUMNS` 를 크게 주는 것이 가장 확실한 대비다. 접히지만 않으면 토큰은 한 덩어리로
나온다. 그래도 접혔을 경우를 대비해 매칭은 버퍼 전체를 대상으로 한다.

**URL 은 파싱하지 않는다.** 실측에서 URL 끝이 잘려 다음 줄에 `0` 만 남은 것을 봤고,
어차피 명령이 브라우저를 직접 열어주므로 가로챌 이유가 없다.

#### 실패하면 조용히 붙여넣기로

- 지정 시간(예: 3분) 안에 토큰이 안 나오면 중단하고 붙여넣기 화면을 연다
- `claude` 실행 파일이 없으면 자동 경로를 아예 제시하지 않는다
- 종료 코드가 0 이 아니면 수집한 출력을 접힌 영역에 보여준다. 사용자가 무슨 일이
  있었는지 볼 수 있어야 한다

어떤 실패든 **붙여넣기로 이어진다.** 막다른 길이 없다.

### 3-2. 브라우저 세션을 격리할 필요가 없다

**앞선 판단을 뒤집는다.** 계정마다 새 쿠키 저장소를 가진 웹뷰를 띄워야 한다고 썼는데,
실제 흐름을 보니 필요없다.

전제가 틀렸다. "계정을 바꾸려면 다른 Anthropic 로그인이 필요하다" 고 봤지만, 실제로는
**한 번 로그인한 뒤 조직을 고르는 구조**다. `Naver`, `NAVER_TEAM_52`, `NAVER_TEAM_40`
이 한 로그인 아래 나란히 있고 매번 어느 것에 연결할지 선택한다.

그래서:

- 로그아웃 절차가 애초에 없다. 여섯 조직을 연달아 등록해도 로그인은 한 번이다
- **세션을 격리하면 오히려 손해다.** 비영속 웹뷰는 SSO 쿠키를 버리므로 조직을 등록할
  때마다 다시 로그인해야 한다. 있던 편의를 없애는 셈이다
- 기본 브라우저를 그대로 쓰는 것이 맞다

정말로 별개 로그인이 필요한 경우(개인 계정과 회사 계정을 함께 쓴다든지)에만 격리가
의미 있다. 그때는 앱이 URL 을 쥐고 있으므로 "다른 계정으로 로그인" 옵션에서만 비영속
웹뷰를 열면 된다. **기본값은 격리하지 않는 것이다.**

### 3-3. 등록하는 김에 검증하고 게이지를 채운다

저장하기 전에 최소 요청을 한 번 보낸다.

```
POST /v1/messages
{ "model": "<가장 싼 모델>", "max_tokens": 1,
  "messages": [{"role": "user", "content": "."}] }
```

얻는 것이 세 가지다.

| 결과 | 처리 |
|---|---|
| `401` | 저장하지 않는다. "토큰이 거부됐습니다" 와 다시 받기 버튼 |
| 네트워크 오류 | 저장하지 않는다. base_url 을 의심하라고 안내 |
| `200` | 저장한다. 그리고 **응답 헤더의 `anthropic-ratelimit-unified-*` 를 그대로 첫 스냅샷으로 쓴다** |

세 번째가 값지다. 이게 없으면 계정 카드가 첫 실제 요청이 흐를 때까지 `n/a` 로 남는다.
등록 직후 게이지가 실제 숫자로 차 있으면 우선순위를 어떻게 잡을지 바로 판단할 수 있다.

비용은 토큰 한두 개다.

---

## 4. 등록 마법사

**토큰을 먼저 받고 이름을 나중에 짓는다.** 순서가 중요하다. 조직은 브라우저에서 고르므로,
이름을 먼저 물으면 "team4 라고 지었는데 브라우저에서 TEAM_52 를 골랐네" 가 된다.
토큰을 받은 뒤에는 사용자가 방금 무엇을 골랐는지 알고 있다.

```
[계정 추가] 누름
   |
   v
1단계  토큰 받기
   |     +-- 자동: claude setup-token 실행
   |     |          -> 앱이 authorize URL 을 열어준다
   |     |          -> 사용자가 브라우저에서 조직을 고른다
   |     |          -> 앱이 stdout 에서 토큰을 집는다
   |     +-- 수동: 명령 복사 버튼 + 붙여넣기 필드
   |               sk-ant-oat01- 접두사, 공백/줄바꿈 제거, 한 줄만
   v
2단계  이름과 요금제
   |     - "방금 브라우저에서 고른 조직 이름을 쓰면 나중에 헷갈리지 않습니다"
   |     - 입력하는 동안 생길 메뉴바 코드를 옆에 보여준다
   |     - 요금제: team / enterprise. 기본 team
   |     - (접힘) 고급: base_url
   v
3단계  검증
   |     최소 요청 1회. 실패하면 이유를 말하고 1단계로 되돌린다
   v
4단계  저장
         Keychain <- 토큰
         accounts.json <- Account + 지문 + 발급 시각 + priority 맨 뒤
         runtime.json <- 검증 응답에서 얻은 첫 RateLimitSnapshot
```

### 이름 규칙

`[A-Za-z0-9_-]+` 만 받는다. 메뉴바 축약 코드가 이름에서 나오므로
([02 도메인 모델](02-domain-model.md) 7절), 입력하는 동안 **생길 코드를 미리
보여준다**. `team40` 을 치면 옆에 `T1` 이 뜨는 식이다. 이름을 정하는 순간 결과를 알
수 있어야 나중에 놀라지 않는다.

조직 이름을 그대로 쓰면 길다(`NAVER_TEAM_40`). 짧게 줄이도록 권하되 강제하지 않는다.
`team40` 이면 충분하다.

이미 있는 이름은 거부한다.

---

## 5. 토큰 만료

`setup-token` 이 주는 토큰은 **1년짜리**다. 발급 시각을 `accounts.json` 에 남기고
만료를 추적한다.

```swift
struct Account {
    // ...
    var tokenCreatedAt: Date        // 등록 시각. 발급 시각의 근사치
    var tokenFingerprint: String    // 6절의 중복 탐지용
}

var expiresAt: Date { tokenCreatedAt.addingTimeInterval(365 * 24 * 3600) }
```

정확한 발급 시각은 알 수 없다. `setup-token` 출력이 "valid for 1 year" 라고만 말하고
발급 타임스탬프를 주지 않는다. 등록 시각을 대신 쓰는데, 자동 캡처 경로에서는 몇 초
차이라 문제없고 붙여넣기 경로에서도 며칠 이내다. 1년 기준에서는 무시할 만하다.

| 남은 기간 | 처리 |
|---|---|
| 30일 초과 | 아무것도 하지 않는다 |
| 30일 이하 | 점검 화면에 표시. 계정 카드에 조용한 표식 |
| 7일 이하 | `tokenExpiringSoon` 조건. 배너와 알림 |
| 만료 | 요청이 401 을 맞고 `invalid` 로 떨어진다. 재등록 안내 |

**만료를 미리 잡는 것이 중요하다.** 그냥 두면 어느 날 갑자기 계정이 하나씩 `invalid`
로 떨어지고, 사용자는 401 만 보고 원인을 모른다. 여섯 계정을 비슷한 시기에 등록했다면
비슷한 시기에 한꺼번에 만료된다.

---

## 6. 같은 계정을 두 번 등록하는 문제

**우리는 토큰이 어느 조직 것인지 알 수 없다.** 사용자는 브라우저에서 골랐지만 앱은 그 화면을 보지 못한다. `setup-token` 이 주는 토큰은
추론 전용 스코프라 신원을 물어볼 엔드포인트가 없다
([01 아키텍처](01-architecture.md) 의 Usage API 제약과 같은 이유).

같은 계정을 `team2` 와 `team5` 로 두 번 등록하면 풀에 계정이 하나인데 항목이 둘이 된다.
전환해도 아무 일이 일어나지 않고, 사용자는 "왜 두 계정이 동시에 소진되지" 하고 의아해
한다.

### 잡을 수 있는 것

**같은 토큰 문자열**은 확실히 잡는다.

```swift
/// 신원 확인이 아니라 중복 붙여넣기 방지용. 토큰 자체는 Keychain 에만 있다.
func fingerprint(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}
```

지문을 `accounts.json` 에 함께 저장하고 등록 시 비교한다. 실수의 대부분인
"직전 토큰을 그대로 다시 붙여넣음" 을 여기서 막는다.

### 잡을 수 없는 것

같은 계정에서 `setup-token` 을 두 번 돌려 얻은 **서로 다른 토큰**은 구분할 방법이 없다.

약한 신호는 있다. 두 계정의 `unified-5h-reset` 시각과 잔여량이 정확히 같으면 같은
계정일 가능성이 높다. 다만 우연히 겹칠 수 있어 자동으로 판단하지 않고, 며칠간 그 상태가
유지되면 점검 화면에 "같은 계정일 수 있습니다" 정도로 띄우는 선에서 그친다.

---

## 7. claulay 에서 가져오기

이미 claulay 를 쓰고 있으면 계정, 토큰, 우선순위가 전부 준비되어 있다. 스무 번의 등록
과정을 한 번으로 줄일 수 있다.

### 읽을 것

| 파일 | 형식 | 담긴 것 |
|---|---|---|
| `~/.claulay/config.yaml` | 평문 YAML | id, type, base_url, priority 순서 |
| `~/.claulay/vault.enc` | AES-256-GCM | id 별 토큰 |

`CLAULAY_HOME` 이 설정되어 있으면 그 경로를 쓴다. 다만 **GUI 앱은 셸 환경변수를
상속하지 않으므로** 자동으로 알 수 없다. 기본 경로를 먼저 보고, 없으면 사용자에게
폴더를 고르게 한다.

### vault.enc 바이너리 배치

claulay `src/vault/cipher.ts` 기준.

```
offset  길이   내용
0       9      매직 "CLAULAY\0\0"
9       1      포맷 버전 (0x01)
10      4      PBKDF2 반복 횟수 (UInt32, 리틀 엔디언)
14      16     salt
30      12     GCM nonce (iv)
42      16     GCM 인증 태그
58      ...    암호문 (JSON: id -> { token, created_at })
```

- KDF: PBKDF2-SHA256, 키 32바이트. 기본 반복 600,000회
- 암호: AES-256-GCM

Swift 에서는 CryptoKit 의 `AES.GCM` 과 CommonCrypto 의 `CCKeyDerivationPBKDF` 로
60줄이면 읽는다.

### 이것이 turn 1 의 원칙을 어기는가

[포팅 README](../porting/README.md) 에서 "보안 로직을 두 벌로 만들지 않는다" 고 했다.
그 원칙은 **지속적으로 유지되는 두 번째 구현**을 금지한 것이다.

이 임포터는 다르다.

- **읽기 전용.** vault 형식으로 쓰지 않는다. 두 번째 진실 공급원이 되지 않는다
- **일회성.** 한 번 가져오면 다시 쓸 일이 없다
- **삭제 가능.** `Sources/ClflStore/Legacy/ClaulayImport.swift` 한 파일에 가두고,
  claulay 사용자가 남지 않으면 통째로 지운다

파일에 그 의도를 주석으로 박아둔다. 나중에 이 코드를 보는 사람이 "여기가 vault 를
다루는 곳이구나" 하고 기능을 얹지 않도록.

### 흐름

```
[claulay 에서 가져오기]
   |
   v
1  config.yaml 을 찾아 읽는다 -> 계정 목록 미리보기 (id, 요금제, 순서)
   |
   v
2  vault 암호구를 묻는다
   |    GUI 앱은 CLAULAY_VAULT_PASS 를 볼 수 없으므로 반드시 입력받는다
   |    복호화 실패 -> "암호구가 맞지 않습니다" 로 되돌림
   v
3  가져올 계정을 고른다 (기본 전체 선택)
   |
   v
4  각 토큰을 검증한다 (2-3 절의 최소 요청)
   |    실패한 계정은 목록에 표시하고 건너뛴다. 나머지는 그대로 진행
   v
5  저장. 우선순위는 config.yaml 의 순서를 그대로 쓴다
```

4단계에서 **일부 실패해도 나머지를 계속 가져간다.** 여섯 개 중 하나가 만료됐다고
전부 되돌리면 사용자가 다섯 개를 손으로 다시 넣어야 한다.

가져온 뒤에도 claulay 설정은 건드리지 않는다. 두 도구를 한동안 같이 쓸 수 있어야 한다.

---

## 8. 재등록 (401 복구)

계정이 `invalid` 가 되면 카드에 재등록 버튼이 뜬다. 흐름은 등록 마법사와 같되
1단계를 건너뛴다. 이름, 요금제, base_url, 우선순위 자리는 그대로 두고 토큰만 바꾼다.

성공하면 `invalidatedAt` 을 지우고 `autoSwitch` 는 원래 값을 유지한다. 사용자가 일부러
빼둔 계정을 재등록했다고 자동으로 다시 켜면 안 된다.

---

## 9. 삭제와 잠시 빼기

| 동작 | 남는 것 | 사라지는 것 |
|---|---|---|
| 자동 전환 끄기 | 전부 | 없음. 선택 후보에서만 빠진다 |
| 계정 삭제 | 사용 기록(`usage.jsonl`, `audit.jsonl`) | Keychain 토큰, accounts.json 항목, 우선순위 자리, runtime 상태 |

삭제는 되돌릴 수 없으므로 확인을 받는다. 대부분의 경우 사용자가 원하는 것은 삭제가
아니라 잠시 빼두기이므로, 확인 창에서 **"대신 자동 전환만 끌까요?"** 를 함께 제시한다.

로그는 지우지 않는다. 지난 사용량 통계에 구멍이 나면 안 되고, 계정 id 는 로그 안에서
그냥 문자열이다.

---

## 10. 구현 메모

- 토큰 문자열을 `Account` 나 `RouterSnapshot` 에 절대 싣지 않는다. UI 로 넘어가는
  값에는 지문만 있다
- 검증 요청은 계정의 `base_url` 을 그대로 쓴다. 기업 게이트웨이 오타를 여기서 잡는다
- 검증 요청에도 `rewriteAuth` 를 쓴다. OAuth 토큰의 `anthropic-beta` 플래그가 빠지면
  멀쩡한 토큰이 401 로 보인다 ([포팅 01](../porting/01-headers-and-auth.md) 2절)
- 마법사 도중 취소하면 아무것도 남기지 않는다. Keychain 쓰기는 마지막 단계에서 한 번

---

## 11. clfl 없이 쓰는 경우

`setup-token` 출력이 알려주는 대로, 조직 하나만 쓸 거라면 clfl 이 필요없다.

```json
// ~/.claude/settings.json
{ "env": { "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-..." } }
```

이것으로 데스크톱 앱이 그 조직으로 붙는다. 프록시도 메뉴바 앱도 없이 동작한다.

**clfl 이 필요한 지점은 정확히 하나다. 조직을 실행 중에 바꾸는 것.** 환경변수는
프로세스 시작 시점에 고정되므로 한도에 걸려도 그 자리에서 다른 조직으로 넘어갈 수 없다.
같은 턴 안에서 조용히 넘기려면 HTTP 경계에 개입하는 수밖에 없고, 그것이 이 프로젝트
전체의 존재 이유다.

이 사실을 README 에 적어두면 사용자가 자기에게 clfl 이 필요한지 스스로 판단할 수 있다.
