# 13. 두 계정을 동시에, 맥락을 옮겨서

[09 문서](09-desktop-org-switch.md)에서 자동 전환을 접었다. 이유는 하나였다.

> 재시작이 필요하고 대화 이력이 끊긴다

그 전제가 틀렸다. 이 문서는 그것을 뒤집는 과정이다.

---

## 1. 딥링크가 있다

앱이 `claude` URL 스킴을 등록해 두고 있다.

```
plutil -extract CFBundleURLTypes json -o - /Applications/Claude.app/Contents/Info.plist
-> [{"CFBundleURLName":"Claude","CFBundleURLSchemes":["claude"]}, ...]
```

세션과 관련된 경로가 셋이다. 전부 실제로 던져서 확인했다.

| 경로 | 하는 일 | 결과 |
|---|---|---|
| `claude://code/new?q=&folder=` | 새 세션. 프롬프트와 폴더 지정 | 된다 |
| `claude://resume?session=<uuid>` | CLI 트랜스크립트를 가져와 연다 | **된다** |
| `claude://code/<cse_\|session_>` | 브리지 세션 | 기능 플래그로 잠김 |

셋째가 잠긴 것은 대조 실험으로 확정했다. 게이트가 없는 `resume` 에 없는 uuid 를
주면 오류 토스트가 뜬다.

```
Couldn't open that session. Its transcript may have been removed.
```

`cse_` 쪽은 아무 반응이 없었다. 앱이 딥링크 실패에 반응은 하므로, 무반응은
그 앞에서 막혔다는 뜻이다.

---

## 2. 계정은 프로세스 전역이다

드롭다운으로 계정을 바꾸면 **돌고 있던 세션이 그 자리에서 끊긴다.** 왜인지가
코드에 있다.

```js
this.currentOrgId = s;
await this.migrateLegacySessions();
await this.loadSessions();          // 세션 맵을 통째로 갈아끼운다
```

`currentOrgId` 는 메인 프로세스의 매니저에 있는 필드 **하나**다. 창을 몇 개
띄우든 같은 값을 본다. 창을 더 여는 것으로는 해결이 안 된다.

`Partitions` 디렉토리가 있어 기대했지만 `cowork-file-preview` 와
`launch-preview-static` 둘뿐이다. 미리보기 렌더링용이지 계정 격리용이 아니다.

---

## 3. 그런데 인스턴스는 여러 개 뜬다

두 가지를 찾았다.

**하나. 단일 인스턴스 잠금이 없다.** 번들 전체에 `requestSingleInstanceLock` 이
없다. 두 번째 프로세스가 그냥 뜬다.

**둘. 데이터 디렉토리를 환경변수로 바꿀 수 있다.**

```js
if (process.env.CLAUDE_USER_DATA_DIR) {
  const A = process.env.CLAUDE_USER_DATA_DIR;
  app.setPath("userData", A);
  app.setPath("logs", resolve(A, "Logs"));
}
```

그래서 이렇게 하면 두 계정이 동시에 산다.

```
CLAUDE_USER_DATA_DIR=~/.claude-alt \
  nohup /Applications/Claude.app/Contents/MacOS/Claude &
```

쿠키가 따로이므로 `lastActiveOrg` 도 따로다. 실측으로 확인했다.

```
기본: 746e81ae-...  (NAVER_TEAM_40)
alt : 2a063dae-...  (NAVER_TEAM_52)
```

원래 인스턴스는 멀쩡하고 돌던 세션도 안 끊긴다. **서로 남남이기 때문이다.**

`open` 으로는 안 된다. LaunchServices 가 셸 환경을 안 물려준다. 실행 파일을
직접 띄워야 환경변수가 먹는다.

---

## 4. 세션 레코드는 포인터일 뿐이다

저장소가 사람과 계정별로 갈려 있다.

```
claude-code-sessions/
  914e4f12-...(계정)/
    746e81ae-...(NAVER_TEAM_40)/
      local_6fcb1fa1-....json
```

```js
getStorageDir() { return join(userDataPath, baseDir, currentAccountId, currentOrgId) }
```

그런데 그 파일 안에 **대화 내용이 없다.**

```json
{
  "sessionId": "local_6fcb1fa1-...",
  "cliSessionId": "6fcb1fa1-...",
  "cwd": "/Users/cpm4/repos/clfl",
  "originCwd": "/Users/cpm4/repos/clfl",
  "lastFocusedAt": 1785648947052,
  "createdAt": 1785646596237,
  "lastActivityAt": 1785646596237,
  "isArchived": false,
  "permissionMode": "default",
  "remoteMcpServersConfig": [],
  "alwaysAllowedReasons": [],
  "sessionPermissionUpdates": []
}
```

내용은 `~/.claude/projects/<프로젝트>/<cliSessionId>.jsonl` 에 있다.
**그 경로는 `CLAUDE_USER_DATA_DIR` 밖이라 인스턴스끼리 공유된다.**

세션 레코드는 "이 사람의 이 계정에서 저 트랜스크립트를 보여줘라" 는 포인터다.
그래서 같은 트랜스크립트를 계정마다 따로 가리킬 수 있다.

Fork 도 같은 원리다. 서버 기능이 아니라 트랜스크립트 파일 복사다.

```js
copyTranscriptUntil(src, dest, uuid)   // 그 메시지 전까지만
await copyFile(src, dest)              // 통째로
```

---

## 5. 그래서 맥락이 계정을 건너간다

`loadSessions()` 가 하는 일은 디렉토리를 읽는 것뿐이다. 인덱스도 서명도 없다.

```js
const c = await readdir(e);
r = Array.from(l).filter(u => u.startsWith("local_") && u.endsWith(".json"));
```

그래서 레코드를 직접 써 넣으면 앱이 다음 기동에 읽는다.

```
~/.claude-alt/claude-code-sessions/<계정>/2a063dae-.../local_<cliSessionId>.json
```

**확인했다.** 비어 있던 alt 인스턴스(NAVER_TEAM_52)의 목록에 세션이 나타났고,
열었더니 대화 내용과 작업 폴더와 git 브랜치까지 그대로 왔다.

```
1. CLAUDE_USER_DATA_DIR 로 두 번째 인스턴스를 띄운다
2. 거기서 다른 계정으로 로그인한다              (최초 한 번)
3. 세션 레코드를 써 넣고 그 인스턴스만 재시작한다
   -> 원래 창은 살아 있고 맥락은 다른 계정에서 이어진다
```

접었던 이유가 사라진다. 드롭다운 전환과 달리 **끊기는 것이 아니라 옮겨 앉는
것**이 된다.

---

## 6. 확인한 것과 안 한 것

| | |
|---|---|
| 두 인스턴스 동시 실행 | 확인 |
| 계정이 서로 독립인가 | 확인. 쿠키를 각각 읽었다 |
| 원래 세션이 안 끊기는가 | 확인. 이 대화가 그 인스턴스에서 돌고 있었다 |
| 레코드 주입으로 세션이 뜨는가 | 확인 |
| 맥락이 오는가 | 확인. 대화, 폴더, 브랜치 |
| **이어서 대화가 되는가** | **안 했다** |
| 재시작 없이 되는가 | 안 된다. 앱이 디렉토리를 감시하지 않는다 |
| 딥링크로 alt 를 지정할 수 있는가 | **안 된다.** 먼저 뜬 인스턴스가 독점한다 |

딥링크가 독점되는 것이 레코드를 직접 쓴 이유다. macOS 는 URL 스킴을 등록된 앱
하나로만 보낸다.

---

## 7. 넘은 선

지금까지 **남의 앱 파일은 읽기만 한다**를 지켜왔다. 여기서는 썼다.

다만 쓴 곳은 **우리가 만든 두 번째 인스턴스의 데이터 디렉토리**다.
`~/.claude-alt` 는 이 실험을 위해 만든 모래상자이고, 사용자가 원래 쓰던
`~/Library/Application Support/Claude` 는 손대지 않았다.

제품으로 만든다면 이 구분을 유지해야 한다. 우리가 만든 인스턴스에만 쓰고,
사용자의 기본 인스턴스는 계속 읽기만 한다.

---

## 8. 이것이 제품에 뜻하는 것

아직 제품이 아니다. 조사 결과다. 하지만 [00 범위](00-scope.md) 2절의 판단
근거가 바뀌었으므로 적어 둔다.

접었던 이유는 "해법이 문제보다 크다" 였다. 맥락이 끊기는 대가가 한도에 걸려
기다리는 것보다 컸기 때문이다. 지금은 그 대가가 없다.

대신 새 대가가 생겼다.

- 인스턴스를 하나 더 띄워야 한다. 메모리도 두 배고 디스크도 341MB 더 쓴다
- 계정마다 한 번씩 로그인해야 한다
- 세션을 옮길 때마다 그 인스턴스를 재시작해야 한다
- 앱의 내부 파일 형식에 기댄다. 앱이 바뀌면 깨진다

마지막 것이 제일 무겁다. 지금 하는 일(사용량 읽기)은 형식이 바뀌면 숫자가
안 보이는 정도지만, 이쪽은 사용자의 작업 흐름 한가운데서 깨진다.
