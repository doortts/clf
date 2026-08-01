# 09. 데스크톱 앱 조직 전환

프록시로 데스크톱 앱을 돌릴 수 없다는 것은 [08 검증](08-verification.md) 7-4절에서
확정했다. 그러면 조직 전환을 밖에서 걸 다른 방법이 있는지가 남는다. 이 문서는
후보를 전부 실측한 기록이다.

---

## 1. 후보와 결과

| 경로 | 결과 | 근거 |
|---|---|---|
| `ANTHROPIC_BASE_URL` 프록시 | 불가 | 앱이 자식 환경에 직접 꽂고 관리 대상 변수로 잠금 |
| 딥링크 `claude://claude.ai/code/?org=` | 불가 | 빈 코딩 창만 열림. 조직 안 바뀜 |
| 딥링크 `claude://claude.ai/?org=` | 불가 | 창도 안 열리고 조직도 그대로 |
| 쿠키 쓰기 (앱 실행 중 + 즉시 반영) | 불가 | 메모리의 값이 UI 를 지배한다 |
| **쿠키 쓰기 (앱 종료 후) + 재시작** | **유망** | 3절 |
| CDP `--remote-debugging-port` | 미검증 | fuse 미차단, argv 필터 없음 |
| 드롭다운 좌표 클릭 | 동작하나 취약 | 5절 |

---

## 2. 앱이 조직을 어디에 담는가

**claude.ai 의 `lastActiveOrg` 쿠키 하나뿐이다.**

Local Storage, Session Storage, IndexedDB, Preferences 를 전부 뒤졌지만 활성 조직을
담은 키가 없다. `organization_uuid` 가 Local Storage 에 있긴 한데 분석 이벤트의
속성값이지 상태가 아니다.

프레임 부트스트랩 코드가 이렇게 읽는다.

```js
const n = new URLSearchParams(location.search).get("org")
const r = document.cookie.match(/(?:^|;\s*)lastActiveOrg=([^;]*)/)[1]
const o = n && valid(n) ? n : (r && valid(r) ? r : null)
if (!o) return
l.set("org", o)                       // /api/frame/<uuid>?org=... 로 나간다
```

URL 의 `?org=` 가 쿠키보다 우선한다. 그런데 딥링크로는 이 경로를 못 탄다.
`claude://claude.ai/code/` 는 세션 id 를 기대하는 코딩 뷰라 쿼리만 주면 빈 화면이
되고, 프레임이 로드되지 않으니 조직도 안 바뀐다.

앱 번들에 `document.cookie = "lastActiveOrg=..."` 를 쓰는 코드가 없다. 즉 **이 쿠키는
서버가 `Set-Cookie` 로 내려준다.** 조직을 바꾸면 서버가 확정해 준다는 뜻이다.

---

## 3. 쿠키는 읽고 쓸 수 있다

값은 Chromium safe storage 로 암호화돼 있지만 키가 Keychain 에 있다.

```
키   = PBKDF2-SHA1(Keychain["Claude Safe Storage"], "saltysalt", 1003회, 16바이트)
IV   = 0x20 * 16
평문 = SHA256(".claude.ai")[32바이트] + 조직uuid
값   = "v10" + AES-128-CBC(평문 + PKCS7 패딩)
```

32바이트 접두사가 `SHA256(host_key)` 라는 것은 실측으로 확인했다. 저장된 값을
복호화한 뒤 같은 절차로 다시 암호화하니 **원본과 바이트 단위로 일치**했다.
쓰기가 가능하다는 증명이다.

`scripts/desktop-org.py` 가 이 절차를 구현한다.

```
desktop-org.py status            지금 활성 조직
desktop-org.py list              로그인된 조직 목록
desktop-org.py switch <이름>      종료 -> 쿠키 쓰기 -> 실행
```

### 앱이 도는 중에 쓰면 어떻게 되나

UI 는 안 바뀐다. 이미 메모리에 든 값으로 그려져 있기 때문이다.

다만 관측해 보니 **Chromium 이 우리가 쓴 값을 되돌리지도 않았다.** 1분을 두고
세 번 확인했지만 디스크의 값은 우리가 쓴 것 그대로였다. 그 쿠키는 조직을 실제로
바꿀 때만 쓰이지 주기적으로 다시 내려쓰는 대상이 아니다.

그래서 순서가 이렇다. **종료 -> 쓰기 -> 실행.** 종료할 때 메모리 값이 마지막으로
디스크에 내려가므로 그 뒤에 써야 우리 값이 남는다.

---

## 4. 진행 중 발견한 함정

**`pgrep -x Claude` 가 실행 중인 앱을 못 잡는다.** 헬퍼 프로세스만 잡히고 메인은
안 잡힌다. 이걸 믿었다가 실행 중인 앱을 꺼졌다고 판정했고, 종료 단계를 통째로
건너뛴 채 쿠키를 썼다. 첫 검증이 무효가 된 원인이다.

신뢰할 수 있는 것은 이것뿐이다.

```bash
osascript -e 'tell application "System Events" to return (name of processes) contains "Claude"'
```

---

## 5. Electron fuse 가 막은 것과 안 막은 것

```
RunAsNode                              꺼짐    ELECTRON_RUN_AS_NODE 불가
NodeCliInspect                         꺼짐    --inspect 불가
EnableCookieEncryption                 켜짐    쿠키 암호화됨 (3절에서 우회)
OnlyLoadAppFromAsar                    켜짐    앱 코드 수정 불가
EmbeddedAsarIntegrity                  켜짐    같은 이유
```

`--remote-debugging-port` 는 **fuse 대상이 아니다.** 메인 바이너리에도 이 스위치를
걸러내는 코드가 없다. 앱을 그 인자로 띄우면 CDP 로 붙어 DOM 을 직접 조작할 수
있을 가능성이 있다. 그러면 재시작 없이, 좌표가 아니라 셀렉터로 전환할 수 있다.
아직 검증하지 않았다.

### 좌표 클릭은 동작한다

드롭다운을 좌표로 눌러 전환하는 것은 실제로 성공했다. 다만 취약하다.

- 웹뷰라 접근성 트리에 텍스트가 없다. 조직 이름으로 항목을 못 찾고 좌표로만 친다
- 좌표가 창 위치와 크기에 묶인다. 창을 옮기면 어긋난다
- 접근성과 화면 기록 권한이 필요하다
- 지금 어느 조직인지 확인하려면 스크린샷을 읽어야 한다

쿠키 경로는 이 넷을 전부 피한다. 조직 확인도 쿠키를 읽으면 끝난다.

---

## 6. 남은 것

| 항목 | 상태 |
|---|---|
| 쿠키 경로가 재시작 후 실제로 먹히는지 | 검증 대기. 앱 종료가 필요해 사용자가 직접 밟는다 |
| CDP 로 재시작 없이 전환 | 미검증 |
| 자동 전환 (한도 임박 시) | 위 둘 중 하나가 확정된 뒤 |
