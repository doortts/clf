# clfl

macOS 메뉴바 앱 - Claude Code 데스크톱 앱을 위한 다중 계정 rate-limit 라우터.

[claulay](https://pages.oss.navercorp.com/chanyeong-cho/claulay/index.html)(Node/TypeScript CLI)의
프록시 코어를 Swift로 포팅하고, CLI가 담당하던 부분을 네이티브 메뉴바 UI로 대체하는 것이 목표다.

---

## 왜 별도 앱인가

claulay는 `claude`를 **자식 프로세스로 spawn하면서 환경변수를 주입**한다. 그런데 Claude Code
데스크톱 GUI 앱은 사용자가 Dock/Finder에서 직접 띄우므로 부모 셸이 없고, macOS GUI 앱은
`~/.zshrc`를 상속하지 않는다(launchd에서 상속). 주입할 지점 자체가 없다.

대신 `~/.claude/settings.json`의 `env` 블록을 쓴다. 공식 문서 기준으로 이 값은
**파일이 변경되면 반영**된다:

```json
{
  "env": { "ANTHROPIC_BASE_URL": "http://127.0.0.1:51710" }
}
```

앱이 상시 실행되며 고정 포트에 로컬 프록시를 띄우고, 위 한 줄을 관리한다.

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
| [UI 시안](docs/design/ui-spec.html) | 동작 원리와 화면 시안 (HTML) |

## 포팅 문서

claulay의 프록시 코어를 Swift로 옮기기 위한 규칙 명세.

| 문서 | 내용 |
|---|---|
| [porting/README](docs/porting/README.md) | 포팅 전략, 모듈 우선순위, 무엇을 버릴지 |
| [01. 헤더 위생과 인증 재작성](docs/porting/01-headers-and-auth.md) | `headers.ts` - OAuth 토큰 처리, 헤더 blocklist, URL 조립 |
| [02. 응답 분류와 쿨다운](docs/porting/02-response-classification.md) | `interceptor.ts` - 스왑 트리거 판정, reset epoch 해석 |
| [03. SSE peek와 스트리밍 패스스루](docs/porting/03-sse-streaming.md) | `stream-peek.ts` 외 - NIO에서 가장 많이 달라지는 부분 |
