# claulay → Swift 포팅 전략

## 원칙

**보안·스트리밍 핵심 로직을 두 벌로 만들지 않는다.** claulay의 프록시 코어는
Anthropic이 문서화하지 않은 429 분류를 실전에서 하나씩 맞으면서 굳힌 결과물이다
(CHANGELOG 51KB). 새로 짜는 것이 아니라 **규칙을 옮기는 것**이다.

**테스트를 먼저 옮긴다.** claulay의 테스트 코드는 소스와 비슷한 분량(~17k LOC)이고,
그 안에 문서 어디에도 없는 지식이 들어 있다. 각 문서 말미의 "테스트 케이스" 절이
그대로 Swift 테스트 명세가 된다.

---

## 무엇을 가져오나

claulay src 총 ~17,000 LOC 중 실제로 스왑을 수행하는 코드는 ~2,000 LOC다.
나머지는 (a) 스왑을 스트림 중간에 안 보이게 하기, (b) detached 자식 프로세스 추적,
(c) statusline 표시, (d) 실전 대응 누적분이다.

| 순위 | 모듈 | LOC | 문서 | 왜 |
|---|---|---|---|---|
| 1 | `proxy/headers.ts` | 203 | [01](01-headers-and-auth.md) | OAuth 토큰 헤더 규칙. 틀리면 인증 자체가 안 됨 |
| 2 | `proxy/interceptor.ts` | 202 | [02](02-response-classification.md) | 스왑 판정 규칙 전체. 도메인 지식의 핵심 |
| 3 | `state/selector.ts` | ~200 | — | 우선순위 선택 + 쿨다운 필터 |
| 4 | `proxy/swap.ts`의 결정 루프 | ~200 | [02](02-response-classification.md) §4 | 1,474줄 중 루프 뼈대만. 나머지는 알림/dedupe |
| 5 | `sse-parser.ts` + `stream-peek.ts` | 415 | [03](03-sse-streaming.md) | 알고리즘만 참고. 구현은 NIO에 위임 |
| 6 | `stream-writer.ts` | 330 | [03](03-sse-streaming.md) §5 | once-write 불변식과 중단 처리 |
| 7 | `telemetry/ratelimit-tracker.ts` | ~300 | — | `anthropic-ratelimit-unified-*` 파싱. 선제 전환의 유일한 데이터 소스 |

## 무엇을 버리나

| 모듈 | LOC | 대체 |
|---|---|---|
| `vault/` | 325 | Keychain |
| `daemon/` 전체 | 2,560 | 앱 자체가 상시 실행 프로세스 |
| `cli/commands/statusline.ts` | 1,154 | 메뉴바 팝오버 |
| `proxy/mitm-*`, `connect-proxy.ts` | ~500 | 보류 (Agent View 백그라운드 워커용) |
| `notice-router.ts`의 dedupe | — | 상태 표시로 대체 (아래 참고) |
| `cli/` 대부분 | ~5,000 | SwiftUI |

### 알림 dedupe를 버리는 이유

claulay는 cross-plan 경고를 `(from, to)` 쌍당 **1시간에 1회**로 억제한다
(`runtime/cross-plan-notice.json`). 이유는 세 가지였다:

1. spawn-per-invocation이라 메모리 플래그가 매번 초기화됨
2. stderr가 파괴적 표면 (Claude Code TUI 화면을 덮어씀)
3. **되돌아볼 기록 화면이 없어서, 놓치면 영영 사라짐**

앱에서는 ②가 해소되고 ③이 역전된다. 영구 타임라인이 있으면 "주기적으로 다시 경고해서
묻히지 않게 한다"는 근거가 사라진다.

더 근본적으로, cross-plan 경고의 본질은 "**지금** cross-plan 상태로 동작 중"이라는
**지속 조건**이다. stderr는 한 줄 찍는 것 말고 할 수 없어서 이걸 이벤트로 강등했고,
그래서 반복 문제가 생겼고, 그래서 dedupe가 필요했다. **dedupe는 표현력 부족을 메우는
우회로였지 설계가 아니다.**

| kind | claulay | clfl |
|---|---|---|
| `cross_plan` | 30분 표시 / 1시간 dedupe | 조건 지속 중 상시 배너 + 타임라인. **dedupe 없음** |
| `auth_401` | 30분 표시 | 계정 카드에 `!` 뱃지 (사용자가 해소할 때까지) |
| `large_request` | 5분 표시 | 타임라인만 |
| `pool_exhausted` | 5분 표시 | 배너 + OS 알림 |

**단, OS 알림에서는 dedupe가 더 중요하다.** 터미널 스팸은 스크롤로 지나가지만 알림센터
스팸은 사용자가 앱 알림을 영구히 꺼버린다. 다만 정책은 타이머가 아니라 **상태 전이 기반**
(`not-crossplan → crossplan` 시 1회)이어야 한다.

> 참고: claulay의 `stale-daemon-notice.json`은 시간 대신 daemon의 `started_at`을 키로 써서
> "그 boot에 대해 정확히 한 번"을 달성한다. **더 정확한 키를 찾으면 타이머가 사라진다**는
> 같은 발상이다.

**구현 규칙: dedupe는 sink 안에 두고, 생산자 쪽에 두지 않는다.** claulay는 dedupe가
`swap.ts`(생산자)에 있어서 이 규칙을 어기고 있다. 소비 표면이 여럿이 되면
한 표면이 dedupe 슬롯을 소모하고 나머지가 침묵하는 버그가 된다.

---

## 스택 선택 근거

| 스택 | 메뉴바 | 프록시 | Windows | 크기 | 평가 |
|---|---|---|---|---|---|
| **Swift + SwiftUI** | `MenuBarExtra` — 네이티브 | swift-nio | ❌ | ~10MB | **채택** |
| Tauri 2 (Rust) | 트레이 지원, popover는 덜 네이티브 | hyper/tokio | ✅ | ~15MB | Windows 필수 시 대안 |
| Flutter (Dart) | 플러그인 의존 | dart:io | ✅ | ~45MB | 기각 |
| Electron (Node) | 무난 | claulay 코드 그대로 | ✅ | ~200MB | 상주 앱엔 과중 |

**Flutter를 기각한 이유:**

1. 메뉴바가 이 앱의 본체인데 거기가 Flutter의 최약점이다. 시스템 트레이가 프레임워크에
   없어 `tray_manager` / `window_manager` 같은 커뮤니티 플러그인에 의존하고,
   `NSStatusItem` + popover UX는 결국 Swift 플랫폼 채널을 직접 뚫어야 나온다.
2. Dart가 3번째 언어가 된다.
3. ~45MB 번들이 메뉴바에 상주한다.

**Swift를 고른 결정적 이유는 swift-nio다.** 이 프로젝트에서 가장 어려운 부분인
SSE 스트리밍 패스스루의 backpressure를 프레임워크가 처리한다. claulay가 860줄 쓴 부분이다.
자세한 내용은 [03](03-sse-streaming.md).

---

## 지름길

프록시를 다시 짜지 않고 **claulay를 단일 실행파일로 컴파일해 사이드카로 번들**하는
방법도 있다(`bun build --compile`). Swift는 UI·Keychain·설정 파일만 담당한다.
검증된 스왑 로직을 그대로 쓰면서 메뉴바 UX를 얻는 가장 빠른 길이고, 나중에 Swift로
옮길 수 있다.
