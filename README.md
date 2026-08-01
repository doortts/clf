# clfl

macOS 메뉴바 앱 - **터미널 Claude Code** 의 사용량 한도를 관리하고 조직 간 전환한다.

> **데스크톱 앱은 대상이 아니다.** 앱이 자식 프로세스 환경에 `ANTHROPIC_BASE_URL` 을
> 직접 꽂고, 그 이름을 관리 대상 변수로 잠가 두었다. 실측으로 확인했다.
> [08 문서 7-4절](docs/design/08-verification.md)

[claulay](https://pages.oss.navercorp.com/chanyeong-cho/claulay/index.html)(Node/TypeScript CLI)의
프록시 코어를 Swift로 포팅하고, CLI가 담당하던 부분을 네이티브 메뉴바 UI로 대체한다.

## 무엇을 위한 도구인가

한도 관리에 집중한다. **API 비용을 얼마 썼는지는 다루지 않는다.**

- 조직마다 5시간과 7일 잔여가 얼마인지
- 어디로 넘어가야 하는지, 언제 넘어가야 하는지
- 모델 하나가 막혔을 때 같은 조직의 다른 모델은 계속 쓸 수 있는지

비슷한 앱인 [CCSwitcher](https://github.com/XueshiQiao/CCSwitcher)가 이미 성숙하고,
프록시를 쓰지 않아 제약도 없다. 그래도 clfl 을 만드는 이유는 셋이다.

1. **한 이메일 아래 조직이 여럿인 환경.** CCSwitcher 는 이메일로 계정을 구분하므로
   같은 SSO 로그인의 조직 여러 개를 등록할 수 없다
2. **모델별 한도.** 계정 단위 전환으로는 `fable` 주간이 소진돼도 `opus` 는 멀쩡한
   상황을 표현하지 못한다
3. **진행 중인 요청 구제.** 자격증명만 바꾸는 방식은 이미 날아간 요청을 되돌릴 수 없다

자세한 대조는 [06 문서](docs/design/06-ccswitcher-comparison.md).

---

## 왜 별도 앱인가

claulay는 `claude`를 **자식 프로세스로 spawn하면서 환경변수를 주입**한다. 앱을 상시
실행으로 두면 그 지점이 없으므로 `~/.claude/settings.json`의 `env` 블록을 쓴다.

```json
{
  "env": { "ANTHROPIC_BASE_URL": "http://127.0.0.1:51710" }
}
```

앱이 상시 실행되며 고정 포트에 로컬 프록시를 띄우고, 위 한 줄을 관리한다.

### 어디에 통하는가

| 표면 | 리디렉션 | 근거 |
|---|---|---|
| 터미널 `claude` | **된다** | 실측. 프록시로 요청이 온다 |
| 데스크톱 앱 | 안 된다 | 앱이 자식 환경에 직접 꽂고 그 이름을 잠가 두었다 |
| Agent View 백그라운드 워커 | 안 된다 | `ANTHROPIC_BASE_URL` 을 무시하고 직접 호출 |

데스크톱 앱을 못 돌리는 것은 설정 문제가 아니라 앱의 정책이다. 자식 프로세스
환경에 `ANTHROPIC_BASE_URL=https://api.anthropic.com` 을 직접 넣고, 사용자가
그 이름으로 환경변수를 넣으려 하면 관리 대상이라며 거부한다. 앱은 자격증명도
직접 쥐고 갱신까지 한다.

그래서 이 도구의 대상은 **터미널에서 쓰는 `claude`** 다. 조직 여러 개를 오가는
자동 전환, 모델별 한도 관측, 진행 중인 요청 구제는 거기서 전부 성립한다.
메뉴바는 그 세션들의 사용량을 보여주고 조직 순서를 관리한다.

### 알려진 대가

`ANTHROPIC_BASE_URL`을 non-first-party 호스트로 지정하면:

- **MCP tool search가 기본 비활성화** - 프록시가 `tool_reference` 블록을 전달한다면
  `ENABLE_TOOL_SEARCH=true`로 복구 가능
- **Remote Control 비활성화** - `api.anthropic.com`이 아니면 동작하지 않음. 우회 방법 없음

---

## claulay 대비 달라지는 것

| 항목 | claulay | clfl |
|---|---|---|
| 프로세스 모델 | spawn-per-invocation | **상시 실행 앱** |
| daemon 계층 | guardian + IPC + lease + lifecycle (~2,560 LOC) | **불필요** - 앱 자체가 daemon |
| 토큰 저장 | `vault.enc` (AES-256-GCM + PBKDF2, ~325 LOC) | **Keychain** |
| passphrase | `CLAULAY_VAULT_PASS` 환경변수 필수 | **불필요** |
| 상태 표시 | statusline hook (~1,154 LOC) | 메뉴바 팝오버 |
| 알림 dedupe | 시간 기반 억제 (`cross-plan-notice.json`) | **상태 표시로 대체** - [03](docs/porting/03-sse-streaming.md) 참고 |
| 계정 전환 | 반응형 (429 수신 후) | 반응형 + **선제 전환**(임계값 기반) |

daemon 계층이 통째로 사라지는 것이 가장 큰 단순화다. claulay의 POSIX 의존성
(unix domain socket, 시그널, 프로세스 상속)은 전부 그 계층에 있었고, 프록시 코어 자체는
플랫폼 중립적이다. 이 때문에 향후 Windows 확장도 열려 있다.

---

## 기술 스택

- **Swift + SwiftUI** - `MenuBarExtra`(macOS 13+)가 메뉴바 앱을 위해 설계된 API
- **swift-nio / AsyncHTTPClient** - 스트리밍 프록시의 backpressure를 프레임워크가 처리
- **Keychain** - 계정별 OAuth 토큰

Flutter/Electron을 쓰지 않는 이유는 [docs/porting/README.md](docs/porting/README.md) 참고.

---

## 설계 문서

앱 전체의 구조와 동작.

| 문서 | 내용 |
|---|---|
| [01. 아키텍처](docs/design/01-architecture.md) | 시스템 경계, 모듈 분해, 동시성 모델, settings.json 소유권 |
| [02. 도메인 모델과 계정 선택](docs/design/02-domain-model.md) | 타입, 계정 상태, 선택 알고리즘, 선제 전환, 영속화 |
| [03. 요청 흐름과 실패 모드](docs/design/03-request-flow.md) | 요청 생애, 시작/종료 시퀀스, 실패 대응, 구현 순서 |
| [04. 구현 설계](docs/design/04-implementation.md) | 패키지 구성, 의존성, 타겟별 API, 동시성 주석, 테스트, 배포 |
| [05. 계정 등록 (폴백)](docs/design/05-account-registration.md) | setup-token 경로, 등록 마법사, claulay 에서 가져오기 |
| [06. CCSwitcher 비교](docs/design/06-ccswitcher-comparison.md) | 자격증명 스왑 방식과의 대조, 전환 전략 비교, 우리 설계의 구멍 |
| [07. OAuth 자격증명](docs/design/07-oauth-credentials.md) | **기본 등록 경로.** 캡처, 갱신, 401 처리, Usage API 취득 정책 |
| [UI 시안](docs/design/ui-spec.html) | 동작 원리와 화면 시안 (HTML) |

## 포팅 문서

claulay의 프록시 코어를 Swift로 옮기기 위한 규칙 명세.

| 문서 | 내용 |
|---|---|
| [porting/README](docs/porting/README.md) | 포팅 전략, 모듈 우선순위, 무엇을 버릴지 |
| [01. 헤더 위생과 인증 재작성](docs/porting/01-headers-and-auth.md) | `headers.ts` - OAuth 토큰 처리, 헤더 blocklist, URL 조립 |
| [02. 응답 분류와 쿨다운](docs/porting/02-response-classification.md) | `interceptor.ts` - 스왑 트리거 판정, reset epoch 해석 |
| [03. SSE peek와 스트리밍 패스스루](docs/porting/03-sse-streaming.md) | `stream-peek.ts` 외 - NIO에서 가장 많이 달라지는 부분 |
